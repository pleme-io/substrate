# Evolving substrate

How to change substrate without breaking the consumers that import it. Read this
before a refactor, a helper extraction, a new build behaviour, or a cleanup wave.

Substrate is imported by most of the fleet. A change here reaches every consumer
on their next `nix flake update`, so a refactor proves it changed nothing, and a
new behaviour arrives switched off.

## The two kinds of change

| Kind | Shape | Proof it is safe |
|---|---|---|
| **Refactor**: extract a helper, move a file, dedupe | output identical to before | derivation-neutral (below): every drvPath unchanged |
| **New behaviour** | a typed parameter whose default is today's behaviour | derivation-neutral for every consumer that does not opt in, plus a test of the new value |

There is no third kind. A change that alters existing outputs without a parameter
is a silent migration of every consumer, and nobody reviews it.

## New behaviour: a typed parameter, default = today

The consumer that needs the behaviour is one permutation of the parameter. Every
other consumer stays on the default and sees no change.

- Take an enum, not a boolean, so the next variant is a value rather than a
  second flag. Check it with `lib.assertOneOf`, so an unknown value fails
  evaluation instead of being ignored.
- Put the default in the parameter itself (`prose ? "included"`), never in the
  consumer.
- Test both directions. The default must be the identity (the same tree, the same
  derivation). The new value must do what it says. An unknown value must throw.

Worked example: `lib/build/source-policy.nix`, where `prose = "included" |
"excluded"` decides whether top-level `docs/` and `*.md` enter a build's source.
Before it, a documentation edit rebuilt and restarted a deployed daemon.
`included` returns `src` untouched, so wiring the policy into `callShape` and the
Rust tool-image builder changed no derivation. One consumer opted in with a
single line. The tests are in `lib/build/tests/source-policy-test.nix`.

## Refactor: the derivation-neutral protocol

1. **Baseline first.** Before editing, record the `drvPath` of every check on
   both systems:
   `nix eval --json .#checks.<system> --apply 'builtins.mapAttrs (_: d: d.drvPath)'`
   for `x86_64-linux` and `aarch64-darwin`.
2. **Edit in a worktree.** Builds and baselines keep reading `main` while you
   edit, and a half-finished edit never leaks into a baseline.
3. **Re-evaluate and compare.** Every pre-existing check must keep an identical
   `drvPath`. Only new checks may be new. Compare the two JSON files with
   `duckdb`, not by eye.
4. **Prove real consumers.** Evaluate a consumer twice, once with
   `--override-input substrate github:pleme-io/substrate/<main-sha>` and once
   with `--override-input substrate path:<worktree>`. The two drvPaths must
   match. Pick consumers that actually reach the code you touched, such as one
   Rust tool, one image, and one Go build.
5. **Distrust an identity that proves nothing.** A consumer whose drvPath
   matches, but whose build never reaches the edited function, proves nothing.
   A web image can match simply because it never touches the Leptos branch you
   changed. When you extract a string or a script, evaluate the enclosing string
   directly, with its interpolations stubbed, before and after, and compare
   the bytes. That probe caught a stray heredoc `EOF` that consumer identity
   would have missed.

### Nix string traps that break neutrality

- In a `''` string, the common indentation is stripped. An interpolation at
  column 0 pins that minimum at 0 and changes every line's indentation. To
  extract a block from a `''` string, keep the interpolation where the block
  used to begin.
- `${import ./x.nix}EOF` is correct only if `x.nix` itself ends with a newline
  and does not contain the terminator line.

## Gates that keep substrate honest

| Gate | What it prevents | Where |
|---|---|---|
| `claude-md-size` | `CLAUDE.md` growing past 40,000. Claude Code does not load a larger file, so every rule in it goes unread. The gate measures bytes, which are never fewer than characters, so it can only err toward failing | `lib/util/claude-md-gate.nix` |
| `checks-wired` | a flake check that no CI step builds, which stays green forever because nothing runs it | `lib/util/checks-wired.nix` |
| workflow path filters | a check whose inputs change without CI running | `.github/workflows/nix-tests.yml` `paths:` |

`checks-wired` compares `attrNames self.checks.x86_64-linux` against the steps in
`nix-tests.yml`. Adding a check therefore means adding its step in the same
commit. The workflow's path filters must also cover every file a check reads. The
filter was missing `lib/tests/**`, `lib/*.nix` and `CLAUDE.md` until those
checks were wired.

A check that has never run is unproven, not green. The first time one is wired,
build it before trusting it (`nix build .#checks.x86_64-linux.<name>`).

## Reuse before writing

| Need | Use |
|---|---|
| turn an eval suite's `runTests` result into a flake check | `testHelpers.mkAsCheck { name; label; } result` (`lib/util/test-helpers.nix`) |
| fetch a flake input at a pinned rev, or use a host tool from one | `lib/util/pinned-flake.nix` (`atRev`, `fromPin`, `hostTool`) |
| bound a context file's size | `lib/util/claude-md-gate.nix` (`check pkgs { name; file; limit ? 40000; }`) |
| assert every check is wired into CI | `lib/util/checks-wired.nix` |
| choose which files a build reads | `lib/build/source-policy.nix` (`buildSrc { src; prose; }`) |
| the hanabi YAML shared by the Leptos and wasm builders | `lib/build/shared/hanabi-config.nix` |

If a shape shows up a second time and none of these fits, extract it into
`lib/util/` or `lib/build/shared/` with a test. Then use the extracted version
for the second copy.

## Keeping `CLAUDE.md` small

`CLAUDE.md` holds the index and the short hard rules. Long material moves into
`docs/` unchanged, gets one index row under "Where the rest lives", and has its
relative links rewritten for the new depth. The size gate fails first if the file
grows again, but the aim is to move material out before the gate has to fire.

## Probing: a negative is evidence about the probe

- `gh run list --branch main` can be stale. To see whether CI ran on a commit,
  read that commit's check-runs (`gh api repos/<r>/commits/<sha>/check-runs`).
- Reading a pipeline through `| tail` or `| head` reports the last stage's exit
  status, not the build's. Capture the result to a file first.
- `PIPESTATUS` is empty in zsh.
- An interactive alias (`rm -i`, `cp -i`) can turn a mutation into a silent
  no-op. Call `/bin/rm` or `/bin/cp`.

## Getting a change onto machines

Pushing substrate reaches no machine. Every consumer pins substrate in its own
`flake.lock`. A change lands on a node only when that node's config repo runs
`nix flake update substrate`, builds, commits and pushes the lock, and the node
rebuilds. The substrate commit is only the first of those steps.

## Deferred backlog

These were found during the 2026-09 cleanup wave and have not been started:

- a faster `nixpkgs.lib` import path for pure eval suites
- an `mkApp` helper for the repeated `apps.<name> = { type = "app"; program = …; }` shape
- shared `systems` sets instead of per-file lists
- sending the remaining ad-hoc source filters through `source-policy`
- moving about 40 inline shell sites to typed tools
- CI caching for the eval jobs
- building JSON as data (`builtins.toJSON`) where it is still assembled as strings
- test gaps in the Go and wasm builders, and eval suites not yet wired into CI

## Known red

`release / Build + push Nix image` for `sql-apply` has failed since 2026-08-26
with GHCR `403: token does not match expected scopes`. The publishing token lacks
`write:packages`. Fixing it is a credential change made through infrastructure
code, not a change in this repo. Every other job is green.
