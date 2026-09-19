# workspace-tests.nix — the lockfile path's test RUNNER: `cargo test` over
# the workspace, as a derivation, against sources vendored from Cargo.lock.
#
# ── THE GAP THIS CLOSES ─────────────────────────────────────────────────
#
# `nix flake check` builds `checks.<system>.*` and nothing else. On the
# default `lockfile` build path (gen's `Cargo.gen.lock` → lockfile-builder
# .nix → nixpkgs `buildRustCrate`) substrate emitted `checks.build` and NO
# `checks.tests`, because that path cannot compile a test target at all:
#
#   * gen's build spec carries no dev-dependency graph (runtime + build
#     edges only; spec-invariants.nix REJECTS a dev edge in either);
#   * the spec's feature sets are resolved for the NON-dev build, while
#     cargo's resolver v2 unifies dev-dependency features into the test
#     build — so even with dev edges, a `#[tokio::test]` whose `macros`
#     feature arrives only through `[dev-dependencies]` would not compile;
#   * `buildRustCrate` has `buildTests` (compile, never run) and no
#     `runTests`, discovers integration tests relative to the WORKSPACE
#     root rather than the member, and has no doctest leg at all.
#
# Each of those is cargo semantics. Re-deriving them in Nix, one at a time,
# is the "second, untested copy of the resolver" test-check.nix refuses. So
# this runner does not re-derive them: it runs CARGO, the real resolver,
# hermetically — `--frozen` over a vendor directory built from the
# workspace's own `Cargo.lock` (every registry crate pinned by the lock's
# checksum, every git crate by its rev). Dev-dependencies, test-profile
# feature unification, integration tests, `CARGO_MANIFEST_DIR`,
# `CARGO_BIN_EXE_*` and doctests all behave exactly as they do under
# `cargo test` on a laptop, because it IS `cargo test`.
#
# ── IT HONOURS THE CARGO [profile] BY CONSTRUCTION ─────────────────────
#
# The buildRustCrate artifact path never reads a Cargo profile — nixpkgs'
# build-crate.nix hard-codes `-C opt-level=3` for every `release = true`
# crate, whatever `[profile.release]` says. This runner injects NO profile:
# no `CARGO_PROFILE_*` variable, no `--release`, no `--profile`. Cargo reads
# the workspace's `[profile.*]` itself, so `[profile.test]`, a custom
# `[profile.stress]` selected with `args = [ "--profile" "stress" ]`, or a
# `[profile.dev] debug-assertions = false` all mean what they say. The e2e
# fixture pins this with a test that only passes when cargo read the
# workspace profile (tests/fixtures/workspace-tests).
#
# ── WHAT IT DOES NOT PROVE (do not round this up) ──────────────────────
#
# It proves the workspace's tests pass under cargo against the locked
# sources. It does NOT prove anything about the buildRustCrate ARTIFACT:
# that path resolves features from gen's spec and applies substrate's crate
# overrides and quirks, and a defect living only there (a wrong feature
# set, a quirk that changes behaviour) is invisible to this runner.
# `checks.build` remains the artifact's compile gate. The buildRustCrate-
# native test path is still the named destination for THAT property and is
# still blocked upstream: `pending-rust-test-check: lockfile-dev-deps`.
#
# Cost: one derivation compiles the whole dependency graph in the test
# profile, uncached per crate. It is OPT-IN for that reason — see
# test-check.nix's `cargo` field. No consumer gets it without asking.
#
# ── SHAPE ───────────────────────────────────────────────────────────────
#
# `{ lib }` → { normalize, argvFor, receiptFor, quirkToolNames,
#              mkWorkspaceTests }.
# The config surface is pure data (strings and lists of strings), so it is
# authorable from any typed front-end and checkable without `pkgs`;
# `mkWorkspaceTests pkgs { … }` is the only function that touches nixpkgs.
{ lib }:

let
  knownConfigFields = [ "runs" "nativeBuildInputs" "buildInputs" "env" ];
  knownRunFields = [ "args" "harnessArgs" ];

  # The runner OWNS hermeticity: it always passes `--frozen` (= `--locked`
  # + `--offline`). A consumer re-stating one is harmless in cargo but is
  # refused here so the argv has exactly one source for that decision.
  ownedFlags = [ "--frozen" "--locked" "--offline" ];

  # A run that compiles tests and executes none is a compile gate wearing a
  # test gate's name — the green-over-nothing this surface exists to stop.
  # Refused, never silently accepted.
  refusedFlags = [ "--no-run" ];

  defaultRun = { args = [ "--workspace" ]; harnessArgs = [ ]; };

  isStringList = v: builtins.isList v && builtins.all builtins.isString v;

  unknownOf = known: attrs:
    builtins.filter (f: !(builtins.elem f known)) (builtins.attrNames attrs);

  # Validate + fill one `runs` entry. `i` is its index, for the message.
  normalizeRun = who: i: run:
    let
      where = "${who} — tests.cargo.runs[${toString i}]";
      unknown = if builtins.isAttrs run then unknownOf knownRunFields run else [ ];
      merged = { args = [ ]; harnessArgs = [ ]; } // run;
      owned = builtins.filter (a: builtins.elem a ownedFlags) merged.args;
      refused = builtins.filter (a: builtins.elem a refusedFlags) merged.args;
    in
      if !(builtins.isAttrs run)
      then throw "substrate/rust: ${where} must be an attrset { args; harnessArgs; }, got ${builtins.typeOf run}."
      else if unknown != [ ]
      then throw ''
        substrate/rust: ${where} — unknown field(s): ${builtins.concatStringsSep ", " unknown}.
        Known fields: ${builtins.concatStringsSep ", " knownRunFields}.
      ''
      else if !(isStringList merged.args)
      then throw "substrate/rust: ${where}.args must be a list of strings (cargo test arguments)."
      else if !(isStringList merged.harnessArgs)
      then throw "substrate/rust: ${where}.harnessArgs must be a list of strings (passed after `--` to the test harness)."
      else if refused != [ ]
      then throw ''
        substrate/rust: ${where} passes ${builtins.concatStringsSep ", " refused}.
        A run that compiles tests without executing them is a compile check
        reported under a test check's name. `checks.build` already proves the
        workspace compiles; this surface only runs tests.
      ''
      else if owned != [ ]
      then throw ''
        substrate/rust: ${where} passes ${builtins.concatStringsSep ", " owned}.
        The runner always passes `--frozen` itself (offline, against the
        vendored Cargo.lock). Drop the flag — hermeticity has one owner.
      ''
      else merged;
in
rec {
  inherit knownConfigFields knownRunFields ownedFlags refusedFlags defaultRun;

  # Validate + fill a consumer's `tests.cargo = { … }` declaration.
  #
  #   runs              — list of `{ args; harnessArgs; }`, one `cargo test`
  #                       invocation each, run in order in ONE build tree so
  #                       they share the compile cache. Default: one run,
  #                       `--workspace`. A CI gate like
  #                       `cargo test --workspace --all-features --all-targets`
  #                       plus a doctest leg (`--all-targets` excludes
  #                       doctests) is two entries.
  #   nativeBuildInputs — nixpkgs attribute NAMES (strings), resolved against
  #   buildInputs         the runner's pkgs. Names, not derivations, so the
  #                       declaration stays pure data.
  #   env               — string → string, exported to every run.
  normalize = who: cfg:
    let
      unknown = if builtins.isAttrs cfg then unknownOf knownConfigFields cfg else [ ];
      merged = { runs = [ defaultRun ]; nativeBuildInputs = [ ]; buildInputs = [ ]; env = { }; } // cfg;
    in
      if !(builtins.isAttrs cfg)
      then throw "substrate/rust: ${who} — `tests.cargo` must be an attrset, got ${builtins.typeOf cfg}."
      else if unknown != [ ]
      then throw ''
        substrate/rust: ${who} — unknown field(s) in `tests.cargo`: ${builtins.concatStringsSep ", " unknown}.
        Known fields: ${builtins.concatStringsSep ", " knownConfigFields}.
      ''
      else if !(builtins.isList merged.runs)
      then throw "substrate/rust: ${who} — `tests.cargo.runs` must be a list."
      else if merged.runs == [ ]
      then throw ''
        substrate/rust: ${who} — `tests.cargo.runs` is empty. A test check
        that runs nothing is green over an empty subject set; omit `runs` to
        get the default (`cargo test --workspace`), or opt out with a reason.
      ''
      else if !(isStringList merged.nativeBuildInputs)
      then throw "substrate/rust: ${who} — `tests.cargo.nativeBuildInputs` must be a list of nixpkgs attribute names."
      else if !(isStringList merged.buildInputs)
      then throw "substrate/rust: ${who} — `tests.cargo.buildInputs` must be a list of nixpkgs attribute names."
      else if !(builtins.isAttrs merged.env && builtins.all builtins.isString (builtins.attrValues merged.env))
      then throw "substrate/rust: ${who} — `tests.cargo.env` must be an attrset of strings."
      # Forced here, not left lazy: a bad run must throw at the declaration,
      # not later inside a derivation attribute nobody happened to read.
      else let runs = lib.imap0 (normalizeRun who) merged.runs;
           in builtins.deepSeq runs (merged // { inherit runs; });

  # The exact argv of one run, after `cargo`. Pure, so the shape of every
  # invocation is assertable without building anything.
  argvFor = run:
    [ "test" "--frozen" ] ++ run.args
    ++ lib.optionals (run.harnessArgs != [ ]) ([ "--" ] ++ run.harnessArgs);

  # What the derivation records it ran. Written by Nix (`builtins.toJSON`),
  # never assembled by the builder, so the receipt cannot disagree with the
  # argv that actually executed.
  receiptFor = { name, cfg }: {
    subject = name;
    runner = "cargo-test-vendored";
    invocations = map (run: [ "cargo" ] ++ argvFor run) cfg.runs;
    env = cfg.env;
  };

  # The native build TOOLS gen's typed quirks name across a spec's crates
  # (protoc, cmake, …) — a build.rs that shells out to one needs it under
  # cargo exactly as under buildRustCrate. Folded through the build's own
  # dispatcher (`applyQuirks`, from quirk-apply.nix), never a second reading
  # of the quirk JSON, so a future quirk kind that contributes
  # nativeBuildInputs reaches the runner with no edit here. The other kinds
  # (cfg forcing, source patches, build-dep folding) compensate for
  # buildRustCrate not being cargo and are deliberately NOT carried: under
  # cargo the upstream crate builds as its authors tested it.
  quirkToolNames = applyQuirks: crates:
    lib.unique (lib.concatMap
      (crate: (applyQuirks (crate.quirks or [ ]) { }).nativeBuildInputs or [ ])
      (builtins.attrValues crates));

  # The test derivation.
  #
  #   pkgs                   — the (native) nixpkgs whose cargo/rustc run it
  #   src                    — the workspace root (must hold Cargo.lock)
  #   name                   — identity, for the derivation name + receipt
  #   config                 — the raw `tests.cargo` declaration
  #   lockFile               — defaults to `src + "/Cargo.lock"`
  #   extraNativeBuildInputs — derivations a caller derives for the consumer
  #   extraBuildInputs         (lockfile-builder passes the spec's
  #                            NativeBuildInputs quirks; tool-release passes
  #                            the consumer's own build inputs)
  mkWorkspaceTests = pkgs: {
    src,
    name,
    config ? { },
    lockFile ? src + "/Cargo.lock",
    extraNativeBuildInputs ? [ ],
    extraBuildInputs ? [ ],
  }:
    let
      cfg = normalize name config;
      byName = n: pkgs.${n} or (throw "substrate/rust: ${name} — `tests.cargo` names nixpkgs attribute `${n}`, which does not exist.");
      receipt = builtins.toJSON (receiptFor { inherit name cfg; });
    in
      if !(builtins.pathExists lockFile)
      then throw ''
        substrate/rust: ${name} — `tests.cargo` needs a committed Cargo.lock
        (looked for ${toString lockFile}). The runner vendors every dependency
        from it and runs `cargo test --frozen`; without it there is nothing to
        pin the test build to.
      ''
      else pkgs.stdenv.mkDerivation {
        # `name` is an identity, not a store-path fragment: mkProject's
        # default is "<unnamed-workspace>", which a store path cannot hold.
        pname = "${lib.strings.sanitizeDerivationName name}-cargo-test";
        version = "0";
        inherit src;

        # nixpkgs' vendoring from the lockfile: registry crates fetched and
        # checked against the lock's own sha256, git crates by rev. The
        # source-replacement config it writes is what makes `--frozen` work.
        cargoDeps = pkgs.rustPlatform.importCargoLock {
          inherit lockFile;
          allowBuiltinFetchGit = true;
        };

        nativeBuildInputs = [
          pkgs.rustPlatform.cargoSetupHook
          pkgs.cargo
          pkgs.rustc
        ]
        ++ map byName cfg.nativeBuildInputs
        ++ extraNativeBuildInputs;

        # Mirrors buildRustCrate: Rust's std links libiconv on darwin.
        buildInputs =
          lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ]
          ++ map byName cfg.buildInputs
          ++ extraBuildInputs;

        env = cfg.env;

        inherit receipt;
        passAsFile = [ "receipt" ];

        # One line per declared run, generated from the typed argv. No
        # loop, no pipe: a failing `cargo test` is the phase's exit status.
        buildPhase = ''
          runHook preBuild
          ${lib.concatMapStringsSep "\n" (run: "cargo ${lib.escapeShellArgs (argvFor run)}") cfg.runs}
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -D -m 0644 "$receiptPath" "$out/receipt.json"
          runHook postInstall
        '';

        passthru = {
          inherit cfg;
          argv = map argvFor cfg.runs;
        };

        meta.description = "cargo test over the ${name} workspace, vendored from Cargo.lock";
      };
}
