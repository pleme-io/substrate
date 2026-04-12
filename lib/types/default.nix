# Substrate Type System
#
# Root aggregation for all substrate types. Provides the complete
# type lattice used by builders, infrastructure archetypes, Kubernetes
# compositions, and validation middleware.
#
# Pure — depends only on nixpkgs lib.
#
# Usage:
#   types = import "${substrate}/lib/types" { inherit lib; };
#   assert types.foundation.nixSystem.check "aarch64-darwin";
#   assert types.foundation.architecture.check "amd64";
#   validated = types.validate.mkTypedBuilder "myBuilder" builderFn;
{ lib }:

{
  # ── Foundation ────────────────────────────────────────────────────
  # Enumerations, refined primitives, and domain-specific leaf types.
  foundation = import ./foundation.nix { inherit lib; };

  # ── Ports ─────────────────────────────────────────────────────────
  # Unified port representation with coercion from legacy formats.
  ports = import ./ports.nix { inherit lib; };

  # ── Build Result ──────────────────────────────────────────────────
  # Universal output contract: { packages, devShells, apps, ... }.
  buildResult = import ./build-result.nix { inherit lib; };

  # ── Build Specs ───────────────────────────────────────────────────
  # Per-language typed input specifications for builder functions.
  buildSpec = import ./build-spec.nix { inherit lib; };

  # ── Service Specs ─────────────────────────────────────────────────
  # Health checks, scaling, resources, monitoring.
  serviceSpec = import ./service-spec.nix { inherit lib; };

  # ── Deploy Specs ──────────────────────────────────────────────────
  # Docker images, registries, targets, releases.
  deploySpec = import ./deploy-spec.nix { inherit lib; };

  # ── Infrastructure Specs ──────────────────────────────────────────
  # Workload archetypes, policies, multi-tier compositions.
  infraSpec = import ./infra-spec.nix { inherit lib; };

  # ── Kubernetes Specs ──────────────────────────────────────────────
  # Resource metadata, security contexts, probes, RBAC.
  kubeSpec = import ./kube-spec.nix { inherit lib; };

  # ── Validation ────────────────────────────────────────────────────
  # Builder wrapping, input/output type checking middleware.
  validate = import ./validate.nix { inherit lib; };
}
