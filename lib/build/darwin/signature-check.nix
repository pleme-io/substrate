let
  codesign = "/usr/bin/codesign";

  verify = lib: path: "${codesign} --verify --strict -- ${lib.escapeShellArg path}";
in
{
  mkDarwinSignatureCheck = { pkgs, name, binaries }:
    assert pkgs.lib.assertMsg (binaries != [ ]) "mkDarwinSignatureCheck ${name}: binaries is empty";
    pkgs.runCommand "darwin-signature-${name}" { } ''
      ${pkgs.lib.concatMapStrings (b: verify pkgs.lib b + "\n") binaries}
      echo "${name}: ${toString (builtins.length binaries)} Mach-O file(s) carry a valid signature at build time" > $out
    '';

  mkDarwinSignatureNegativeControl = { pkgs, name, binary }:
    pkgs.runCommand "darwin-signature-negative-control-${name}" { } ''
      install -m 0755 ${binary} tampered
      install -m 0755 ${binary} unsigned
      printf '\377' | dd of=tampered bs=1 seek=16384 conv=notrunc status=none
      ${codesign} --remove-signature unsigned
      ${verify pkgs.lib "tampered"} && { echo "a tampered binary verified" >&2; exit 1; }
      ${verify pkgs.lib "unsigned"} && { echo "an unsigned binary verified" >&2; exit 1; }
      echo "${name}: the verifier rejects a tampered and an unsigned copy" > $out
    '';
}
