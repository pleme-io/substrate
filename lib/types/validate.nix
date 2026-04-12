# Substrate Type Validation Middleware
#
# Higher-order functions that wrap builder functions with type checking.
# The validation happens at the module evaluation boundary — input specs
# are validated before reaching the builder, and outputs are checked
# against the BuildResult contract.
#
# This is the Resolve layer in convergence theory — where declarations
# are resolved to typed, validated values.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) evalModules;
  buildResultTypes = import ./build-result.nix { inherit lib; };
  buildSpecTypes = import ./build-spec.nix { inherit lib; };
in rec {
  # ── Output Validation ─────────────────────────────────────────────
  # Validate that a builder's return value conforms to BuildResult.
  # Returns the validated result unchanged if valid; throws with a
  # descriptive error if any field fails its type check.
  #
  # Usage:
  #   validated = validateBuildResult "mkMyBuilder" rawResult;
  validateBuildResult = builderName: result:
    let
      # Only validate fields that are present in the result.
      # This allows builders to return extra backward-compat fields
      # alongside the standard ones.
      standardFields = [ "packages" "devShells" "apps" "overlays" "checks" "meta" ];
      filtered = lib.filterAttrs (k: _: builtins.elem k standardFields) result;
      eval = evalModules {
        modules = [
          buildResultTypes.buildResultModule
          { config = filtered; }
        ];
      };
    in
      # Return the ORIGINAL result (with extra fields preserved),
      # but only after validation succeeds.
      if (builtins.tryEval (builtins.seq eval.config result)).success
      then result
      else throw "${builderName}: output does not conform to BuildResult contract. Check packages, devShells, and apps fields.";

  # ── Builder Wrapping ──────────────────────────────────────────────
  # Wrap a builder function so its return value is type-checked.
  # The wrapped function has the identical signature as the original.
  #
  # Usage:
  #   mkMyTool = mkTypedBuilder "mkMyTool" originalMkMyTool;
  #   result = mkMyTool { name = "foo"; src = ./.; };  # type-checked
  mkTypedBuilder = builderName: builderFn: args:
    validateBuildResult builderName (builderFn args);

  # ── Input Validation ──────────────────────────────────────────────
  # Validate a build spec against a language-specific type.
  # Returns the evaluated (and default-filled) config.
  #
  # Usage:
  #   spec = validateSpec "rust" { name = "auth"; src = ./.; };
  #   # spec now has all defaults filled, types checked
  validateSpec = language: spec:
    let
      specType = buildSpecTypes.specsByLanguage.${language}
        or (throw "validateSpec: unknown language '${language}'. Known: ${toString (builtins.attrNames buildSpecTypes.specsByLanguage)}");
      eval = evalModules {
        modules = [
          { options.spec = lib.mkOption { type = specType; }; }
          { config.spec = spec; }
        ];
      };
    in eval.config.spec;

  # ── Typed Builder with Input + Output Validation ──────────────────
  # The full pipeline: validate input spec, call builder, validate output.
  #
  # Usage:
  #   mkMyService = mkFullyTypedBuilder "rust-service" "mkMyService" originalBuilder;
  mkFullyTypedBuilder = language: builderName: builderFn: rawArgs:
    let
      validatedArgs = validateSpec language rawArgs;
      rawResult = builderFn validatedArgs;
    in validateBuildResult builderName rawResult;

  # ── Type Check Predicate ──────────────────────────────────────────
  # Non-throwing version: returns { valid, errors } instead of throwing.
  # Useful for testing and conditional logic.
  checkBuildResult = result:
    let
      standardFields = [ "packages" "devShells" "apps" "overlays" "checks" "meta" ];
      filtered = lib.filterAttrs (k: _: builtins.elem k standardFields) result;
      tryEval = builtins.tryEval (
        let eval = evalModules {
          modules = [
            buildResultTypes.buildResultModule
            { config = filtered; }
          ];
        };
        in builtins.seq eval.config true
      );
    in {
      valid = tryEval.success && tryEval.value;
      errors = if tryEval.success then [] else [ "BuildResult type check failed" ];
    };
}
