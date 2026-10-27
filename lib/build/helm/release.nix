# substrate/lib/build/helm/release.nix
#
# A Helm release as a typed declaration, rendered by mkHelmRender.
#
#   release = import "${substrate}/lib/build/helm/release.nix" { inherit pkgs; };
#   options.releases = lib.mkOption { type = lib.types.attrsOf release.type; };
#   release.render "pangea" config.releases.pangea      # typed value -> manifest
#   release.renderDecl "pangea" { chart = …; values = …; }  # raw attrs, checked first
#
# Moved from pleme-io/nix lib/engenho-helm-release.nix (2026-10-27), so the
# declaration and the renderer live in one place. A chart that ships a
# values.schema.json refuses a value outside it when the release renders
# (helm validates on template; locked by checks.<system>.helm-render).
{ pkgs }:
let
  lib = pkgs.lib;
  mkHelmRender = import ./render.nix { inherit pkgs; };

  type = lib.types.submodule (
    { name, ... }: {
      options = {
        chart = lib.mkOption {
          type = lib.types.path;
          description = "The chart directory, typically a flake input's committed, generated chart.";
        };
        libraries = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = { };
          description = "Library charts the chart depends on, by name, as unpacked directories (e.g. \"\${helmworks}/charts/pleme-lib\"). Vendored offline; no registry is reached.";
        };
        vendoredDeps = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = { };
          description = "Other dependencies as chart archives: a fixed-output .tgz or a mkHelmChart output.";
        };
        values = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Values over the chart's defaults. A chart with a values.schema.json refuses a value outside it when the release renders.";
        };
        namespace = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The namespace the release renders into.";
        };
        release = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The Helm release name.";
        };
        createNamespace = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Render the Namespace object; the node-manifests driver creates none itself.";
        };
        renderName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The rendered manifest's store name; null names it after the release key.";
        };
        extraObjects = lib.mkOption {
          type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
          default = [ ];
          description = "Objects appended after the chart's render, each as one more YAML document (JSON).";
        };
        includeCrds = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Render the chart's crds/ directory too.";
        };
      };
    }
  );

  render = name: r:
    mkHelmRender {
      name = if r.renderName == null then name else r.renderName;
      inherit (r)
        chart libraries vendoredDeps values namespace release
        createNamespace includeCrds extraObjects;
    };

  check = name: decl:
    (lib.evalModules {
      modules = [
        { options.releases = lib.mkOption { type = lib.types.attrsOf type; }; }
        { releases.${name} = decl; }
      ];
    }).config.releases.${name};
in
{
  inherit type render check;
  renderDecl = name: decl: render name (check name decl);
}
