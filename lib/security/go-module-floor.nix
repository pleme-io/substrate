{ lib }:
{
  withGoModuleFloor =
    {
      requires,
      vendorHash,
    }:
    drv:
    let
      floors = lib.concatStringsSep " " (lib.mapAttrsToList (m: v: "${m}@${v}") requires);
      raise = _: previous: {
        preBuild = (previous.preBuild or "") + ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          for floor in ${floors}; do
            module="''${floor%@*}"
            want="''${floor#*@}"
            have="$(go list -m -f '{{.Version}}' "$module" 2>/dev/null || true)"
            if [ -n "$have" ] && [ "$have" != "$want" ] \
              && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n1)" = "$have" ]; then
              go get "$module@$want"
            fi
          done
          go mod tidy
        '';
        postInstall = (previous.postInstall or "") + ''
          cp go.mod "$out/.go-module-floor.mod"
          cp go.sum "$out/.go-module-floor.sum"
        '';
      };
    in
    drv.overrideAttrs (old: {
      inherit vendorHash;
      passthru = (old.passthru or { }) // {
        overrideModAttrs = lib.composeExtensions (old.passthru.overrideModAttrs or (_: _: { })) raise;
        goModuleFloor = requires;
      };
      postConfigure = (old.postConfigure or "") + ''
        cp vendor/.go-module-floor.mod go.mod
        cp vendor/.go-module-floor.sum go.sum
      '';
    });
}
