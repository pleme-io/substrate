# substrate/lib/build/python/uv-test-runner.nix
#
# mkUvSyncSnippet — emit the shell prelude that any flake-app needs
# when its body wants to invoke uv-locked Python tools (pytest,
# ansible, akeyless SDK, etc.) without re-resolving deps on every run.
#
# The snippet is the only shell that should remain in a tatara-lisp-
# driven flake app: it materializes the venv into a per-host cache
# (keyed by uv.lock's sha256, so re-runs are no-ops) and exports the
# venv's `bin` to PATH so the subsequent `exec ${mkTataraScript ...}`
# resolves pytest/ansible/etc. from the lock-pinned wheels. Logic --
# sops decrypt, container lifecycle, HTTP polling, pytest invocation,
# matrix summary -- belongs in the .tlisp body, not here.
#
# Why a string-returning function and not a derivation:
#   `uv sync` writes to $PWD/.venv at runtime (it has to, because the
#   venv path embeds the consumer's project root for editable installs
#   to work). A pure-Nix build can't predict that path. The snippet
#   captures the *recipe* in a substrate-blessed form so every consumer
#   uses the same one.
#
# Required attrs:
#   pkgs                — nixpkgs instance
#
# Optional attrs:
#   python              — Python interpreter (default: pkgs.python3)
#   cacheSubdir         — name under XDG_CACHE_HOME for the lockhash
#                          file (default: "ansible-akeyless-livetest"
#                          for backward-compat; new consumers should
#                          override to a project-specific name)
#   uvLockPath          — path to uv.lock relative to $PWD at
#                          invocation time (default: "uv.lock")
#   projectDir          — uv --project value (default: "$PWD")
#   noiseFilter         — regex of uv-sync output lines to suppress so
#                          a clean run is silent (default suppresses
#                          the "Using/Resolved/Installed/…" status
#                          chatter)
#
# Usage in a flake app:
#
#   live-coverage = {
#     type = "app";
#     program = toString (pkgs.writeShellScript "my-app" ''
#       set -euo pipefail
#       ${substrateLib.mkUvSyncSnippet { inherit pkgs; cacheSubdir = "my-app"; }}
#       exec ${mkTataraScript "my-app" (builtins.readFile ./run.tlisp)}
#     '');
#   };
#
# The tlisp body inherits PATH (with .venv/bin) and inherits process
# env, so any (env-set …) calls plumb into subsequent exec-check
# children that resolve to the lock-pinned interpreter.
{
  mkUvSyncSnippet = {
    pkgs,
    python ? pkgs.python3,
    cacheSubdir ? "ansible-akeyless-livetest",
    uvLockPath ? "uv.lock",
    projectDir ? "$PWD",
    noiseFilter ? "^(Using|Resolved|Installed|Audited|Built|\\s+\\+)",
  }: ''
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/${cacheSubdir}"
    lockhash=$(${pkgs.coreutils}/bin/sha256sum ${uvLockPath} | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    if [ ! -f "$cache/.lockhash" ] || [ "$(cat "$cache/.lockhash")" != "$lockhash" ]; then
      echo "[uv-sync] materializing venv for ${uvLockPath} $lockhash"
      ${pkgs.uv}/bin/uv sync --frozen --python ${python}/bin/python3 \
        --project "${projectDir}" --no-progress 2>&1 \
        | ${pkgs.gnugrep}/bin/grep -vE '${noiseFilter}' || true
      mkdir -p "$cache"
      echo "$lockhash" > "$cache/.lockhash"
    fi
    export PATH="$PWD/.venv/bin:$PATH"
  '';
}
