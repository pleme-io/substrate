# Render an action.yml string from a typed Nix attrset.
#
# Mirrors `arch-synthesizer/src/action_domain/render.rs`'s rendering shape
# 1:1, so the Rust + Nix sides emit equivalent output for the same typed
# declaration. (Once arch-synthesizer's CLI ships a `render-action`
# subcommand this becomes a thin caller into the binary; until then the
# Nix-side renderer keeps the typed-output discipline holding when a
# consumer's flake.nix needs to emit action.yml without going through
# arch-synthesizer.)
#
# Inputs:
#   toolName : string — kebab-case action name (also the repo name)
#   action   : attrset {
#                description : string
#                inputs      : list of { name; description; required ? false; default ? null; }
#                outputs     : list of { name; description; }
#              }
#   lib      : nixpkgs.lib (for toUpper / concatStringsSep / replaceStrings)
#
# Output: a single string (the rendered action.yml).
#
# Security shape: every `${{ inputs.<name> }}` reaches the binary via an
# INPUT_<UPPER_NAME> env var, never via shell interpolation in `run:`.
# Satisfies Semgrep's `yaml.github-actions.security.run-shell-injection`
# by construction.
{ toolName, action, lib }:
let
  inputs  = action.inputs  or [];
  outputs = action.outputs or [];

  inputEnvName = name:
    "INPUT_" + (lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name));

  yamlQuote = s:
    "\"" + (lib.replaceStrings
      [ "\\" "\"" "\n" ]
      [ "\\\\" "\\\"" "\\n" ]
      s) + "\"";

  renderInput = input:
    let
      head = "  ${input.name}:\n"
        + "    description: ${yamlQuote input.description}\n"
        + "    required: ${if (input.required or false) then "true" else "false"}";
      withDefault =
        if input ? default && input.default != null
        then head + "\n    default: ${yamlQuote input.default}"
        else head;
    in withDefault;

  inputsBlock =
    if inputs == []
    then ""
    else "inputs:\n" + (lib.concatStringsSep "\n" (map renderInput inputs)) + "\n\n";

  renderOutput = output:
    "  ${output.name}:\n"
    + "    description: ${yamlQuote output.description}\n"
    + "    value: \"\${{ steps.run.outputs.${output.name} }}\"";

  outputsBlock =
    if outputs == []
    then ""
    else "outputs:\n" + (lib.concatStringsSep "\n" (map renderOutput outputs)) + "\n\n";

  envEntries =
    [ "        BINARY_PATH: \"\${{ steps.download.outputs.binary }}\"" ]
    ++ (map (input:
      "        " + (inputEnvName input.name)
        + ": \"\${{ inputs." + input.name + " }}\""
    ) inputs);

  envBlock = lib.concatStringsSep "\n" envEntries;
in ''
name: ${yamlQuote toolName}
description: ${yamlQuote action.description}

${inputsBlock}${outputsBlock}runs:
  using: composite
  steps:
    - id: download
      shell: bash
      run: |
        # binary download glue (filled in by the consumer flake's release
        # workflow; see substrate/lib/build/rust/action-release-flake.nix)
        echo "placeholder until release workflow ships the GH-release download"

    - id: run
      shell: bash
      env:
${envBlock}
      run: |
        # All inputs reach this script as env vars (INPUT_*),
        # never as $${{ }} interpolation. The action's binary reads them
        # via pleme_actions_shared::Input::from_env().
        "$BINARY_PATH" || true
''
