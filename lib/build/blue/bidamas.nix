# `mkBidama` — a bidama IS a derivation.
#
# ## Why this exists
#
# The first version of `bidamas/flake.nix` packaged the whole distribution as
# one store path and called nix "the pinning layer". That was too small a claim
# to be worth making: it pinned bytes without ever modelling a package.
#
# This makes the mapping structural instead. **One bidama, one derivation, and
# the `needs(...)` in its `Bluefile` become that derivation's real nix
# dependencies** — so the dependency graph blue's resolver computes and the
# graph nix builds are the same graph, not two descriptions of one that can
# drift apart.
#
# What that buys, and none of it is new machinery — it is what a derivation
# already is:
#
#   * a bidama is content-addressed by its inputs, so two builds resolving the
#     same package cannot disagree about its contents;
#   * a missing dependency is a build failure, not a runtime "unbound symbol";
#   * `nix build .#kazu` works on one package without materialising the rest;
#   * the fleet's caching applies unchanged — a bidama substitutes like anything
#     else, so the distribution inherits the binary cache for free.
#
# This follows the fleet's `mk<Thing>` builder convention (substrate's
# `rust-tool-release-flake.nix`, `mkDarwinAppBundle`, `mkHelmChartPackages`):
# one function, typed arguments, a complete derivation out.
#
# ## Nix reads blue's evaluation; it does not re-derive it
#
# A `Bluefile` is *blue code* — `needs("kazu", "^0.1")` is a call, and its
# arguments can be computed. Nix cannot evaluate blue without
# import-from-derivation, so it reads what blue already computed: each
# package's committed `Bluefile.lock`, written by `blue lock` and parsed here
# with `builtins.fromJSON` (phase P1).
#
# This replaced a `builtins.match`/`splitString` scrape of the manifest text,
# which was wrong for a computed `needs` — measured on 2026-08-02 by rewriting
# one `zenbu` entry as `computed = "moji"` / `needs(computed, "^0.1")`: blue
# resolved 17 dependencies, the scrape saw 16, and the facade's closure shipped
# one bidama short with nothing going red. The scrape is DELETED, not kept as a
# fallback: a package with no lock is refused below, loudly.
#
# Tier: **eval- and CI-caught, not unrepresentable.** A stale lock can be
# committed; `mkLockCheck` (the `bidama-locks-fresh` flake check) runs
# `blue bluefile --confirm` over every package and fails on it, and
# `granularity.rs::the_locked_and_evaluated_dependency_views_agree` compares
# every lock against blue's resolver from `cargo test`.

#
# ## Form is the producer's check; meaning is the build
#
# A bidama's layout and its machine-fixable rules (form) are judged by the
# blue its producer pins, in the producer's own `checks` (`passthru.formCheck`,
# `checks.bidama-form-<pkg>` under `lib.project`). The build judges meaning
# only (`BLUE_FORM=none`), because a consumer whose flake makes the producer
# follow its blue builds the producer's bidamas with the CONSUMER's blue, and
# that blue's newer formatter must never fail the consumer (R1 in
# `docs/COMPOUNDING.md`: three ryn builds failed on one afternoon this way).
# The loader compiles a store dependency as written, so a bidama built by an
# older or newer blue still loads. Red run, 2026-10-23: `mkCheckRefusalCheck`
# with the build's step put back on `form = "own"` failed on its form fixture.

{ lib, runCommand, symlinkJoin ? null, makeWrapper ? null, makeBinaryWrapper ? null, blue ? null }:

let
  topBlue = blue;
  blueFor = what: given:
    if given != null then given
    else throw ''
      ${what} needs `blue`: a bidama is built only from canonical source, and
      blue's formatter is what says what canonical is. Pass `blue` to
      mk-bidama.nix (blue.lib.bidamas, overlays.bidamas and lib.project do).
    '';

  # The wrapper every blue executable gets. makeBinaryWrapper when the caller
  # passes it: a compiled exec wrapper, so no shell runs between the caller and
  # blue. makeWrapper (a bash script) stays as the fallback for callers that
  # pin the older argument set (makoto imports this file from a pinned blue).
  wrapper =
    if makeBinaryWrapper != null then { pkg = makeBinaryWrapper; fn = "makeBinaryWrapper"; }
    else if makeWrapper != null then { pkg = makeWrapper; fn = "makeWrapper"; }
    else null;
  wrapperGiven = what: lib.assertMsg (wrapper != null)
    "${what} needs makeBinaryWrapper (or makeWrapper); pass the full pkgs set";

  # The lock layout this file reads. `blue_lang_pkg::lock::LOCK_SCHEMA`; a lock
  # from another layout is refused rather than half-read.
  lockSchema = 1;

  # A package's `Bluefile.lock`, parsed. Refuses a package with no lock, or one
  # in a layout this file was not written against.
  lockOf = { name, src }:
    let path = src + "/Bluefile.lock";
    in
    if !builtins.pathExists path then
      throw ''
        bidama "${name}" has no Bluefile.lock. Nix reads blue's evaluation of
        the Bluefile rather than guessing at it; write it with
        `blue lock <dir>` and commit it.
      ''
    else
      let lock = builtins.fromJSON (builtins.readFile path);
      in
      if lock.schema != lockSchema then
        throw ''
          bidama "${name}": Bluefile.lock has schema ${toString lock.schema}, and
          mk-bidama.nix reads schema ${toString lockSchema}. Relock with the blue
          this distribution pins.
        ''
      else if lock.manifest.name != name then
        throw ''
          bidama "${name}": its Bluefile declares package("${lock.manifest.name}", …).
          The directory and the package must agree, or the registry resolves
          the wrong thing.
        ''
      else lock;

  # Dependency names, from the lock's evaluated `needs`.
  depsOf = lock: builtins.attrNames lock.manifest.needs;

  # The version `package(...)` declared — stated once, by the package, in blue.
  # A directory called `kazu-0.1.0` would be a second place for it to be wrong.
  versionOf = lock: lock.manifest.version;

  # Every package directory under a distribution root: a directory holding a
  # Bluefile. One definition, read by `mkDistribution` and `mkLockCheck`, so
  # the packages built and the packages gated cannot differ.
  packageDirs = root:
    lib.filterAttrs
      (n: t: t == "directory" && builtins.pathExists (root + "/${n}/Bluefile"))
      (builtins.readDir root);

  levelsUnder = dir:
    let
      levels = lib.filterAttrs
        (n: t: t == "directory" && builtins.pathExists (dir + "/${n}/${n}.b"))
        (builtins.readDir dir);
    in
    lib.concatMap (n: [ n ] ++ map (l: "${n}/${l}") (levelsUnder (dir + "/${n}"))) (builtins.attrNames levels);

  treeNodeCount = root:
    lib.foldl'
      (acc: n: acc + 1 + builtins.length (levelsUnder (root + "/${n}")))
      0
      (builtins.attrNames (packageDirs root));

  treeLevels = root:
    lib.mapAttrs (n: _: levelsUnder (root + "/${n}")) (packageDirs root);

in
rec {
  inherit lockOf depsOf versionOf packageDirs treeNodeCount treeLevels;

  # Build ONE bidama.
  #
  # `all` is the attrset of every built bidama, passed in so a package can
  # depend on its siblings — the knot `mkDistribution` ties below.
  # The check stage over a bidama's source, against its dependency closure:
  # every rule in blue's registry (unbound and implicit names, types,
  # imports and needs), so a package whose code does not check does not
  # BUILD, not only fail a separate test. One fragment, so the gate that
  # proves it refuses (`mkCheckRefusalCheck`) runs exactly what mkBidama runs.
  # `form` is BLUE_FORM: "none" in the build, which judges meaning only,
  # because a consumer's blue may build a producer's bidama; "own" in the
  # producer's form check.
  checkStep = { blue, name, src, bluePath, form ? "none", keep ? null }: ''
      rm -rf check-root
      mkdir check-root
      cp -r ${src} check-root/${name}
      chmod -R u+w check-root
      for f in check-root/${name}/*.b; do
        if ! ${lib.optionalString (keep != null) "XDG_CACHE_HOME=${keep} "}BLUE_FORM=${form} BLUE_PATH=${bluePath} ${blue} check "$f" > check.log 2>&1; then
          cat check.log >&2
          echo "bidama ${name}: the check stage refuses $f (above); a bidama that does not check does not build" >&2
          exit 1
        fi
      done
  '';

  # Every bidama `names` reach, for BLUE_PATH: the names, their needs, and
  # theirs, as each dependency's derivation recorded them.
  closureOf = all: names:
    let
      go = acc: ds: lib.foldl'
        (seen: d: if lib.elem d seen then seen else go (seen ++ [ d ]) (all.${d}.bidamaDeps or [ ]))
        acc
        ds;
    in
    go [ ] names;

  mkBidama = { name, src, all ? { }, blue ? topBlue }:
    let
      fmt = "${blueFor "mkBidama ${name}" blue}/bin/blue";
      lock = lockOf { inherit name src; };
      version = versionOf lock;
      deps = depsOf lock;
      resolved = map
        (d:
          all.${d} or (throw ''
            bidama "${name}" needs "${d}", which is not in the distribution.

            A dependency that does not exist must fail HERE, at build time,
            rather than at runtime as an unbound symbol — that is the whole
            reason a bidama is a derivation.
          ''))
        deps;
      closure = closureOf all deps;
      bluePath = lib.concatMapStringsSep ":" (d: "${all.${d}}") closure;
    in
    runCommand "bidama-${name}-${version}"
      {
        inherit version;
        outputs = [ "out" "analysis" ];
        buildInputs = resolved;
        passthru = {
          bidamaDeps = deps;
          bidamaName = name;
          formCheck = runCommand "bidama-form-${name}-${version}" { } ''
            if ! (cd ${src} && BLUE_PATH=${bluePath} ${fmt} fmt --check *.b); then
              echo "bidama ${name}: the file(s) above are not canonical under this blue; run blue fmt --write on each and commit" >&2
              exit 1
            fi
            ${checkStep { blue = fmt; inherit name src bluePath; form = "own"; }}
            touch $out
          '';
        };
        meta.description = "blue bidama: ${name}";
      } ''
      ${checkStep { blue = fmt; inherit name src bluePath; }}

      mkdir -p $out/${name}
      cp -r ${src}/* $out/${name}/

      # A bidama must carry source. An empty package resolves fine and then
      # fails at import with nothing to point at.
      if [ -z "$(find $out/${name} -name '*.b' -print -quit)" ]; then
        echo "bidama ${name} contains no .b source" >&2
        exit 1
      fi

      # Record the resolved dependency STORE PATHS, not just their names.
      #
      # This is load-bearing and was a real bug: an earlier version wrote only
      # the names, and `nix-store -q --references` on the result returned ZERO.
      # `buildInputs` alone gives build-time ORDERING; a store reference exists
      # only if the output actually mentions the path. So `nix build .#retsu`
      # produced a retsu whose closure did not contain kazu — the dependency
      # was recorded and not delivered, which is the worst of both (it reads as
      # wired and behaves as absent).
      #
      # Writing the paths makes the edge real: the closure now carries every
      # dependency, `nix-store -q --references` shows them, and a consumer that
      # copies a bidama gets its dependencies with it.
      : > $out/${name}/.bidama-deps
      ${lib.concatMapStringsSep "\n"
          (d: ''echo "${d}" >> $out/${name}/.bidama-deps'')
          (map toString resolved)}

      # The analysis output (HORIZON H3 rung 2): the check above, run again
      # from a distribution laid out as a consumer's (real directories,
      # files linked to their store paths), keeping its check store. A key
      # holds which file sits under which root, so only this layout's
      # entries are the ones the installed blue asks for.
      mkdir -p $TMPDIR/dist $analysis
      cp -rs $out/${name} $TMPDIR/dist/${name}
      ${lib.concatMapStringsSep "\n" (d: "cp -rs ${all.${d}}/${d} $TMPDIR/dist/${d}") closure}
      ${checkStep { blue = fmt; inherit name; src = "$TMPDIR/dist/${name}"; bluePath = "$TMPDIR/dist"; keep = "$TMPDIR/blue-cache"; }}
      if [ -d $TMPDIR/blue-cache/blue/check ]; then
        cp -r $TMPDIR/blue-cache/blue/check $analysis/check
      fi
    '';

  # A single `BLUE_PATH` root containing the given bidamas.
  #
  # ## Why this is the whole nix-native claim, in one function
  #
  # `blue_lang_pkg::LoadPath` searches roots whose immediate children are
  # package directories, and `mkBidama` above produces exactly `$out/<name>/`.
  # So a bidama's store path is ALREADY a valid root — there is no install
  # step, no manifest translation, no adapter between "what nix built" and
  # "what the runtime loads". Joining several of them yields one root holding
  # a chosen set of packages:
  #
  #     BLUE_PATH=$(nix build --no-link --print-out-paths .#bluePath)
  #
  # The loader cannot tell a store path from a working tree, which is the
  # property worth having: the same code path serves `nix develop` and a
  # developer's checkout, so what CI runs is what the laptop ran.
  #
  # Closure-complete by construction — `mkBidama` writes each dependency's
  # store PATH into the output, so joining a package brings its dependencies
  # whether or not the caller listed them.
  mkBluePath = { bidamas, name ? "blue-path" }:
    assert lib.assertMsg (symlinkJoin != null)
      "mkBluePath needs symlinkJoin; pass the full pkgs set";
    symlinkJoin { inherit name; paths = lib.attrValues bidamas; };

  # `blue`, with the distribution baked in as `BLUE_DIST`.
  #
  # The reason to wrap rather than document an export: an operator who has to
  # set an environment variable to make imports work will one day not set it,
  # and the failure — an unresolved package — reads as a broken distribution
  # rather than a missing variable. A wrapper makes the working configuration
  # the only one that ships.
  #
  # The distribution goes on `BLUE_DIST`, not `BLUE_PATH`: BLUE_PATH is the
  # caller's override, BLUE_DIST the installed distribution, and the loader
  # searches the file's project before either (`blue_lang_pkg::load_path`).
  # Until 2026-10-23 this suffixed BLUE_PATH, and a pin older than the
  # repository an editor had open answered "no bidama named" for a package the
  # repository defines. `--suffix`, so a caller's own BLUE_DIST roots still
  # come first. mkOverrideCheck and mkProjectFirstCheck below are the gates.
  #
  # `bin` names the executable (a project's runner is its own name, so it can
  # sit on a PATH beside `blue`), and `tools` are appended to PATH — appended,
  # so a node's own copy of a tool wins over the pinned one.
  mkAnalysis = { bidamas, name ? "blue-analysis" }:
    assert lib.assertMsg (symlinkJoin != null)
      "mkAnalysis needs symlinkJoin; pass the full pkgs set";
    symlinkJoin {
      inherit name;
      paths = lib.concatMap (b: lib.optional (b ? analysis) b.analysis) (lib.attrValues bidamas);
    };

  mkBlueWithBidamas = { blue, bidamas, name ? "blue-with-bidamas", bin ? "blue", tools ? [ ], analysis ? true }:
    assert wrapperGiven "mkBlueWithBidamas";
    let distribution = mkBluePath { inherit bidamas; }; in
    runCommand name {
      nativeBuildInputs = [ wrapper.pkg ];
      meta.mainProgram = bin;
      passthru = { inherit blue distribution; };
    } ''
      mkdir -p $out/bin
      ${wrapper.fn} ${blue}/bin/blue $out/bin/${bin} ${lib.concatStringsSep " " (
        [ ''--suffix BLUE_DIST : "${distribution}"'' ]
        ++ lib.optional analysis ''--suffix BLUE_CACHE_SHARED : "${mkAnalysis { inherit bidamas; }}"''
        ++ lib.optional (tools != [ ]) ''--suffix PATH : "${lib.makeBinPath tools}"''
      )}
    '';

  # Proves the wrapper is a default and not a cage: a root on the caller's
  # BLUE_PATH holding a package with the SAME name as one in the distribution
  # must win. The program calls a marker only the caller's copy defines; the
  # negative control runs it without BLUE_PATH and must fail, so a pass cannot
  # come from a distribution that happens to define the marker too.
  mkOverrideCheck = { blue, bidamas, name ? "blue-path-override" }:
    let wrapped = mkBlueWithBidamas { inherit blue bidamas; }; in
    runCommand name { } ''
      mkdir -p override/retsu
      printf 'def precedence_marker()\n  42\nend\n' > override/retsu/retsu.b
      printf 'use("retsu", [:precedence_marker])\nwrite_file(getenv("MARK", "mark"), to_s(precedence_marker()))\n' > prog.b
      if MARK=$PWD/control ${wrapped}/bin/blue run prog.b > control.log 2>&1; then
        echo "negative control passed: the distribution's retsu defines the marker"; exit 1
      fi
      BLUE_PATH=$PWD/override MARK=$out ${wrapped}/bin/blue run prog.b
      test "$(cat $out)" = 42
    '';

  # Proves the installed distribution never shadows the project a file sits
  # in: a project whose own `retsu` defines a marker the pinned retsu lacks
  # runs it through the wrapper, under BLUE_PATH holding a stale retsu too.
  mkProjectFirstCheck = { blue, bidamas, name ? "blue-project-first" }:
    let wrapped = mkBlueWithBidamas { inherit blue bidamas; }; in
    runCommand name { } ''
      mkdir -p proj/pkgs/retsu stale/retsu
      printf 'package("pf-proj", "0.1.0")\npackages("pkgs")\n' > proj/Bluefile
      printf 'package("retsu", "0.1.0")\n' > proj/pkgs/retsu/Bluefile
      printf 'def precedence_marker()\n  42\nend\n' > proj/pkgs/retsu/retsu.b
      printf 'use("retsu", [:precedence_marker])\nwrite_file(getenv("MARK", "mark"), to_s(precedence_marker()))\n' > proj/prog.b
      printf 'package("retsu", "0.1.0")\n' > stale/retsu/Bluefile
      printf 'def stale()\n  0\nend\n' > stale/retsu/retsu.b
      BLUE_PATH=$PWD/stale MARK=$out ${wrapped}/bin/blue run proj/prog.b
      test "$(cat $out)" = 42
    '';

  # The catalogue of a distribution: every package, its gloss, and every
  # definition with its doc line, rendered by the `mokuroku` bidama.
  #
  # Discovery without a documentation server. The same markdown is committed
  # beside the distribution (GitHub renders it, codesearch indexes it), and
  # `mkCatalogCheck` below fails when the committed copy is stale. This is the
  # docs.rs / pkg.go.dev role, filled by a derivation.
  #
  # `bidamas` must include `mokuroku` itself, which is what renders the page.
  # `root` is the one root to catalogue — a project's own packages, so a
  # private distribution's catalogue does not go stale every time the public
  # one changes (makoto's `tools/catalog.b` made the same choice). Without it,
  # every root on BLUE_PATH is catalogued.
  mkCatalog = { blue, bidamas, root ? null, name ? "bidama-catalog" }:
    let
      program = builtins.toFile "catalog.b" ''
        use("mokuroku", %i[blue_path_roots catalog_of render_markdown])
        roots = blue_path_roots(getenv("CATALOG_ROOTS", getenv("BLUE_PATH", "")))
        write_file(getenv("GEN_OUT", ""), render_markdown(catalog_of(roots)))
      '';
    in
    runCommand name { } ''
      ${lib.optionalString (root != null) "CATALOG_ROOTS=${root} "}GEN_OUT=$out BLUE_PATH=${mkBluePath { inherit bidamas; }} ${blue}/bin/blue run ${program}
    '';

  # Fails when the committed catalogue differs from a fresh render.
  mkCatalogCheck = { blue, bidamas, committed, root ? null, name ? "bidama-catalog-fresh" }:
    mkFreshCheck {
      inherit name committed;
      generated = mkCatalog { inherit blue bidamas root; };
      regenerate = "nix run .#regen";
    };

  # One file generated by a blue program: the program writes it to $GEN_OUT.
  #
  # The general shape behind every committed artifact blue produces: the
  # catalogue, and Rust that blue writes for its own crates through the `sabi`
  # bidama (`crates/blue-lang-syntax/gen/kigou.b`). "We write bluelang, we
  # leverage nix": the program is blue, and nix runs it, caches it, and gates it.
  # `root`, when given, is a directory of the project paths the program
  # declared it reads (the Bluefile's `generate(…, inputs)`), exported as
  # $GEN_ROOT; without it the derivation is exactly what it was before.
  mkGenerated = { blue, bidamas, program, name, tools ? [ ], root ? null }:
    runCommand name { nativeBuildInputs = tools; } ''
      ${lib.optionalString (root != null) "GEN_ROOT=${root} "}GEN_OUT=$out BLUE_PATH=${mkBluePath { inherit bidamas; }} ${blue}/bin/blue run ${program}
    '';

  # A blue program run as its own cached derivation — the Bluefile's
  # `run(name, file[, reads])`. The program writes into the directory
  # `$RUN_OUT`, and finds each run it reads at `$RUN_READS/<name>`.
  #
  # A run that writes nothing FAILS. An empty output is what a program that
  # ignored `$RUN_OUT` produces, and it would otherwise be cached as a success
  # and read downstream as "no results" rather than as the bug it is.
  #
  # `reads` is an attrset of run derivations keyed by run name; the farm holds
  # one symlink per read, so a reader's inputs are exactly the runs it names
  # and nothing else (makoto's `-- reads:` line, as a declaration).
  mkRun = { blue, bidamas, program, name, reads ? { }, tools ? [ ], root ? null }:
    let
      farm = runCommand "${name}-reads" { } ''
        mkdir -p $out
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (r: d: "ln -s ${d} $out/${r}") reads)}
      '';
    in
    runCommand name { nativeBuildInputs = tools; passthru = { inherit reads; }; } ''
      mkdir -p $out
      ${lib.optionalString (root != null) "GEN_ROOT=${root} "}RUN_OUT=$out RUN_READS=${farm} BLUE_PATH=${mkBluePath { inherit bidamas; }} ${blue}/bin/blue run ${program}
      if [ -z "$(ls -A $out)" ]; then
        echo "run ${name}: the program wrote nothing into \$RUN_OUT" >&2
        exit 1
      fi
    '';

  # A test file as a check: `blue test`, whose status is the check's. A file
  # with no `test` blocks fails (`blue test` refuses it), so a check cannot
  # pass over nothing. The tally is the output, for reading after the fact;
  # with `coverage`, the coverage record too (`--coverage --json`), which
  # `checks.test-beside` reads instead of running the tests again.
  mkTestCheck = { blue, bidamas, file, name, tools ? [ ], root ? null, env ? { }, coverage ? false }:
    let
      bluePath = mkBluePath { inherit bidamas; };
      envPrefix = lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v} ") env);
      command = "${envPrefix}${lib.optionalString (root != null) "GEN_ROOT=${root} "}BLUE_PATH=${bluePath} ${blue}/bin/blue test ${file}${lib.optionalString coverage " --coverage --json"}";
    in
    runCommand name { nativeBuildInputs = tools; passthru.test = { inherit command root file tools bluePath; }; } ''
      ${command} > $out
    '';

  # Fails when a committed generated file differs from a fresh generation. The
  # message names `regenerate`, the command that rewrites the file in place,
  # so a stale file is fixed by that command and never by copying a store path
  # over it; then it shows the first lines of the difference.
  mkFreshCheck = { generated, committed, name, regenerate }:
    runCommand name { } ''
      if ! cmp -s ${generated} ${committed}; then
        echo "${name}: the committed file is stale. Regenerate it: ${regenerate}" >&2
        diff ${committed} ${generated} | head -40 >&2
        exit 1
      fi
      touch $out
    '';

  # A blue program as an executable: `blue run <program>` with the given
  # bidamas on BLUE_PATH, and `blue` itself on PATH so the program can run
  # other blue programs. The shape behind `nix run .#regen`, and behind the
  # Bluefile's `app` word (`nix/project.nix`, phase P6).
  #
  # The program is a `.b` file (`program`) or its text (`source`, written into
  # the package as share/blue/<name>.b); exactly one. `env` is set on every run
  # as a default, so the caller's own environment wins where it names the same
  # variable. This is the one way a blue program becomes an installable
  # executable: on PATH, behind a launchd agent or a systemd unit (substrate's
  # `services.tehai` is a caller). substrate carried a copy of it,
  # `mkBlueProgramPackage`, for one day (2026-09-27), before recon found this.
  mkBlueApp = { blue, bidamas, name, program ? null, source ? null, tools ? [ ], env ? { }, chdir ? null }:
    assert wrapperGiven "mkBlueApp";
    assert lib.assertMsg ((program == null) != (source == null))
      "mkBlueApp ${name}: give exactly one of `program` (a .b file) or `source` (its text)";
    let
      file = if program != null then "${program}" else "$out/share/blue/${name}.b";
      flags =
        [
          ''--suffix BLUE_PATH : "${mkBluePath { inherit bidamas; }}"''
          ''--prefix PATH : "${blue}/bin"''
        ]
        ++ lib.optional (tools != [ ]) ''--suffix PATH : "${lib.makeBinPath tools}"''
        ++ lib.mapAttrsToList (k: v: "--set-default ${lib.escapeShellArg k} ${lib.escapeShellArg v}") env
        ++ lib.optional (chdir != null) "--chdir ${lib.escapeShellArg chdir}"
        ++ [ ''--add-flags "run --quiet ${file} --"'' ];
    in
    runCommand name
      ({ nativeBuildInputs = [ wrapper.pkg ]; meta.mainProgram = name; }
        // lib.optionalAttrs (source != null) { inherit source; passAsFile = [ "source" ]; })
      ''
        mkdir -p $out/bin
        ${lib.optionalString (source != null) ''mkdir -p $out/share/blue && cp "$sourcePath" "${file}"''}
        ${wrapper.fn} ${blue}/bin/blue $out/bin/${name} ${lib.concatStringsSep " " flags}
        HOME=$TMPDIR BLUE_CHECK_CACHE=off BLUE_PATH="${mkBluePath { inherit bidamas; }}" \
          ${blue}/bin/blue check ${file} > /dev/null
      '';

  # Fails when two packages define the same name.
  #
  # blue's namespace is flat across imports, so such a pair breaks any program
  # that imports both, and the error surfaces far from its cause (an arity
  # mismatch inside someone else's code). `owned`, when given, limits the
  # gate to collisions touching those packages: a private distribution checks
  # itself against the public one without failing on the public one's choices.
  #
  # With `owned`, the scan must also have READ every owned package (the
  # positive control): a scan that missed them reports zero collisions for
  # them and passes. Taken from makoto's `tools/collisions.b`. Red run,
  # 2026-09-24: owned = [retsu, not-a-package] → red; [retsu, kazu] → green.
  # `scope`: "distribution" refuses a name two packages define (what blue's
  # single global environment needed); "namespace" refuses a name one package
  # defines twice, and allows the rest, since per-bidama namespaces key every
  # definition by its package. The default is the old rule, so a project on a
  # blue from before namespaces keeps its gate unchanged.
  mkCollisionCheck = { blue, bidamas, owned ? null, name ? "bidama-collisions", scope ? "distribution" }:
    let
      ownedList = "[${lib.concatMapStringsSep ", " (o: ''"${o}"'') owned}]";
      mine = if owned == null then "records" else "filter(fn(r) contains(${ownedList}, pkg_name(r)) end, records)";
      query =
        if scope == "namespace"
        then "namespace_duplicates(${mine})"
        else if owned == null
        then "name_collisions(records)"
        else "name_collisions_touching(records, ${ownedList})";
      # What the gate program lists from each bidama: exactly what it reads,
      # which depends on `owned` (an unread listed name is B0016).
      mokurokuNames =
        [ "blue_path_roots" "catalog_of" ]
        ++ (if scope == "namespace" then [ "namespace_duplicates" ]
            else if owned == null then [ "name_collisions" ] else [ "name_collisions_touching" ])
        ++ lib.optional (owned != null) "pkg_name";
      retsuNames = (lib.optional (owned != null) "contains") ++ [ "is_empty" "size" ];
      list = names: lib.concatMapStringsSep ", " (n: ":" + n) names;
      seen = lib.optionalString (owned != null) ''
          scanned = map(fn(r) pkg_name(r) end, records)
          assert is_empty(filter(fn(o) contains(scanned, o) == false end, ${ownedList})) == true
      '';
    in runCommand name { } ''
      cat > gate.b <<'EOF'
      use("mokuroku", [${list mokurokuNames}])
      use("retsu", [${list retsuNames}])
      test "no two packages define one name"
        records = catalog_of(blue_path_roots(getenv("BLUE_PATH", "")))
        assert size(records) > 0
      ${seen}
        found = ${query}
        println(found)
        assert is_empty(found) == true
      end
      EOF
      ${blue}/bin/blue fmt --write gate.b
      BLUE_PATH=${mkBluePath { inherit bidamas; }} ${blue}/bin/blue test gate.b
      touch $out
    '';

  # Build every bidama in a distribution directory, wiring the graph.
  #
  # `lib.fix` ties the knot: each package receives the finished attrset, so
  # `retsu` can reference `kazu` without the distribution being ordered by hand.
  # A dependency CYCLE therefore surfaces as nix's own infinite-recursion error
  # rather than as a silently truncated graph — the loud failure is the correct
  # one, and blue's solver reports cycles too, so the two agree on rejection.
  mkDistribution = { root, pkgs, blue ? topBlue }:
    lib.fix (all:
      lib.mapAttrs
        (name: _: mkBidama {
          inherit name all blue;
          src = root + "/${name}";
        })
        (packageDirs root));

  # Fails when any package's committed `Bluefile.lock` is not blue's
  # evaluation of the Bluefile beside it — edited without relocking, edited by
  # hand, or written by a blue that evaluates differently.
  #
  # One `blue bluefile --confirm` over every package: blue reports each one and
  # exits non-zero if any is stale, so this is a single command, not a loop.
  #
  # Red run, 2026-09-23: `needs("moji", "^0.1")` added to `bidamas/kazu/Bluefile`
  # without relocking → `nix build .#checks.aarch64-darwin.bidama-locks-fresh`
  # failed with `{"status":"stale","reason":{"kind":"hash",…}}` naming kazu and
  # `run \`blue lock …/kazu\``; the other 20 packages reported fresh. Reverted.
  # One Bluefile and its lock, confirmed: the lock must be blue's evaluation of
  # the Bluefile. For a project-level Bluefile (a repository's own build facts)
  # rather than a distribution of packages, which `mkLockCheck` covers.
  mkBluefileCheck = { blue, bluefile, lock, name ? "bluefile-lock-fresh" }:
    runCommand name { } ''
      mkdir project
      cp ${bluefile} project/Bluefile
      cp ${lock} project/Bluefile.lock
      ${blue}/bin/blue bluefile --confirm project/Bluefile
      touch $out
    '';

  # `roots` for a project with several `packages(...)` roots; `root` for one.
  # Fails when a Bluefile's needs cannot be SOLVED against `bidamas`, the same
  # package set the build composes. `mkLockCheck` proves a lock is blue's
  # evaluation of its Bluefile, and `mkBidama` only that a needed package
  # EXISTS; neither runs the version solver. So an unsatisfiable range passed
  # every gate. Red run 2026-09-25: nupastel's `abura` with
  # `needs("retsu", "^0.9")` against retsu 0.1.0 made `blue deps` exit 1
  # while `nix flake check` stayed green; with this check it goes red.
  #
  # A manifest given as a PATH is interpolated through its directory, so the
  # package is copied into the store and becomes an input of the check.
  # `escapeShellArgs` alone calls `toString`, which yields the path's text with
  # no context: the check then named a file its sandbox could not see, and
  # `native-bidama-deps-resolve` failed on Linux CI with `Bluefile: No such
  # file or directory` (it passed on a machine whose store already held it).
  # mkLockCheck interpolates its roots the same way.
  mkResolveCheck = { blue, bidamas, manifests, name ? "bidama-deps-resolve" }:
    let
      inStore = m: if builtins.isPath m then "${dirOf m}/${baseNameOf m}" else m;
    in
    runCommand name { } ''
      for m in ${lib.escapeShellArgs (map inStore manifests)}; do
        BLUE_PATH=${mkBluePath { inherit bidamas; }} ${blue}/bin/blue deps "$m" >> $out || exit 1
      done
    '';

  # Proves the split between the producer's form and everyone's meaning. A
  # bidama whose `use` follows its definitions (B0015, a form rule) is refused
  # by the producer's form check and still BUILDS, because a consumer must
  # never fail on a dependency's form. A bidama that reaches its dependency's
  # `one` only through flat visibility (B0012) does not build: the runtime's
  # namespaces do not bind that name, so it is meaning. The fixtures are
  # written here, not committed, so the repository's own corpus stays free of
  # errors. The positive control is the dependency, built by mkBidama itself.
  mkCheckRefusalCheck = { blue, name ? "bidama-check-refuses" }:
    let
      bin = "${blue}/bin/blue";
      dep = mkBidama {
        name = "refusal_dep";
        inherit blue;
        src = runCommand "refusal-dep-src" { } ''
          mkdir -p $out
          printf 'def one()\n  1\nend\n' > $out/refusal_dep.b
          printf 'package("refusal_dep", "0.1.0")\n' > $out/Bluefile
          cd $out && ${bin} lock . > /dev/null
        '';
      };
      bad = runCommand "refusal-bad-src" { } ''
        mkdir -p $out
        printf 'use("refusal_dep")\n\ndef two()\n  one + one\nend\n' > $out/refusal_bad.b
        printf 'package("refusal_bad", "0.1.0")\nneeds("refusal_dep", "^0.1")\n' > $out/Bluefile
      '';
      formy = runCommand "refusal-form-src" { } ''
        mkdir -p $out
        printf 'def two()\n  refusal_dep::one + refusal_dep::one\nend\n\nuse("refusal_dep")\n' > $out/refusal_form.b
        printf 'package("refusal_form", "0.1.0")\nneeds("refusal_dep", "^0.1")\n' > $out/Bluefile
      '';
    in
    runCommand name { } ''
      if (${checkStep { blue = bin; name = "refusal_bad"; src = bad; bluePath = "${dep}"; }}) 2> refused.log; then
        echo "${name}: mkBidama's check step built a bidama with a B0012 in it" >&2
        exit 1
      fi
      grep -q 'B0012' refused.log
      if (${checkStep { blue = bin; name = "refusal_form"; src = formy; bluePath = "${dep}"; form = "own"; }}) 2> form.log; then
        echo "${name}: the form check passed a bidama with a B0015 in it" >&2
        exit 1
      fi
      grep -q 'B0015' form.log
      if ! (${checkStep { blue = bin; name = "refusal_form"; src = formy; bluePath = "${dep}"; }}) 2> built.log; then
        cat built.log >&2
        echo "${name}: the build refused a bidama for its form, which is its producer's" >&2
        exit 1
      fi
      cat refused.log form.log > $out
    '';

  # Fails when any `.b` file under `root` is not `blue fmt` canonical, naming
  # each one. blue's own repository holds its whole tree to the one layout this
  # way (the `blue-fmt` flake check); a package is held by `mkBidama` itself.
  # One command over every file, not a loop: `blue fmt --check` takes several.
  # Red run, 2026-09-27: one bad line in spec/arithmetic.b and one in
  # bidamas/angou/angou.b → red, naming both files; restored → green.
  mkFmtCheck = { blue, root, name ? "blue-fmt" }:
    runCommand name { } ''
      cd ${root}
      if ! find . -name '*.b' -exec ${blue}/bin/blue fmt --check {} +; then
        echo "${name}: the file(s) above are not canonical; run blue fmt --write on each" >&2
        exit 1
      fi
      touch $out
    '';

  mkLockCheck = { blue, root ? null, roots ? [ root ], name ? "bidama-locks-fresh", bluePath ? null }:
    let
      manifests = lib.concatMap
        (r: map (n: "${r}/${n}/Bluefile") (lib.attrNames (packageDirs r)))
        roots;
    in
    runCommand name { } ''
      ${lib.optionalString (bluePath != null) "BLUE_PATH=${bluePath} "}${blue}/bin/blue bluefile --confirm ${lib.escapeShellArgs manifests}
      touch $out
    '';
}
