{ lib }:
{
  withGoSymbolTable =
    drv:
    drv.overrideAttrs (old: {
      ldflags = lib.filter (flag: flag != "-s") (
        lib.concatMap (flag: lib.splitString " " flag) (old.ldflags or [ ])
      );
    });

  withGoModuleFloor =
    {
      requires,
      vendorHash,
    }:
    drv:
    let
      floors = lib.concatStringsSep " " (lib.mapAttrsToList (m: v: "${m}@${v}") requires);
      raise = _: previous: {
        preBuild = (previous.preBuild or "") + "\n" + ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          for floor in ${floors}; do
            module="''${floor%@*}"
            want="''${floor#*@}"
            have="$(go list -mod=mod -m -e -f '{{if not .Error}}{{.Version}}{{end}}' "$module")"
            if [ -n "$have" ] && [ "$have" != "$want" ] \
              && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n1)" = "$have" ]; then
              echo "go-module-floor: $module $have -> $want"
              go get "$module@$want"
            fi
          done
          go mod tidy -e
          built="$(go list -mod=mod -e -deps -f '{{with .Module}}{{.Path}}{{end}}' ./...)"
          for floor in ${floors}; do
            module="''${floor%@*}"
            want="''${floor#*@}"
            have="$(go list -mod=mod -m -e -f '{{if not .Error}}{{.Version}}{{end}}' "$module")"
            if ! printf '%s\n' "$built" | grep -qxF "$module"; then
              [ -n "$have" ] && echo "go-module-floor: $module $have provides no package to this build"
              continue
            fi
            if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n1)" != "$want" ]; then
              echo "go-module-floor: $module is $have after the raise, below $want" >&2
              exit 1
            fi
          done
        '';
        postInstall = (previous.postInstall or "") + "\n" + ''
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
      postConfigure = (old.postConfigure or "") + "\n" + ''
        cp "''${goModules:-vendor}/.go-module-floor.mod" go.mod
        cp "''${goModules:-vendor}/.go-module-floor.sum" go.sum
      '';
    });
}
