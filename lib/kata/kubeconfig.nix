# kata.kubeconfig — render a per-cluster kubeconfig ARTIFACT from typed
# cluster-access facts.
#
# kata already DESCRIBES clusters (domains, fleet registries); nothing
# RENDERED the access artifact. Three+ consumers hand-typed the same YAML
# block — profiles/fleet-rio-kubectl (token + insecure-skip-tls-verify),
# profiles/darwin-developer/k3s-cluster.nix (client-cert + CA data per
# local-VM cluster), profiles/nixos-k3s-server/home/kubeconfig.nix, and
# users/luis/plo/kubeconfig.nix. This letter is the one typed renderer
# that block collapses into: typed cluster-access facts in, a kubeconfig
# as a Nix attrset out, ready to serialize (pkgs.formats.yaml/json) and
# have its placeholders substituted at the CONSUMER's activation.
#
# SECRET DISCIPLINE (read this): the rendered `config` carries the secret
# REFS verbatim (sops placeholder strings, paths, "$SECRET_TOKEN", …) — it
# NEVER inlines a secret value, because this is pure { lib } with no I/O
# and no decryption capability. The token/clientCert/clientKey/CA refs are
# placeholders; the consumer's activation (HM sops template, system sops,
# envsubst) is what materializes them. A rendered `config` is therefore
# safe to `git`-commit / `nix eval` — it contains only references.
#
# Composition note: this letter is data-only (zero pkgs). It pairs with
# iroha.option-surface.render (which serializes a value via
# pkgs.formats.<fmt>) and with the consumer's secret backend — kata draws
# the shape, the consumer pours the secret in.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkKubeconfig :: {
#     clusters :: attrsOf clusterSpec (required, non-empty) — keyed by
#                 cluster name; each clusterSpec =
#       {
#         server :: str (required) — "https://host:port" API endpoint;
#         auth   :: { kind = "token";      tokenRef :: str (placeholder); }
#                 | { kind = "clientCert"; clientCertRef :: str;
#                                          clientKeyRef  :: str; }
#                 — exactly one ref-bearing variant; tokenRef / cert refs
#                   are PLACEHOLDERS, never inlined secrets;
#         caRef                  ? null (str) — CA cert ref/path placeholder
#                                  (certificate-authority);
#         caData                 ? null (str) — base64 CA bundle
#                                  (certificate-authority-data); used when
#                                  the bytes are known at render time;
#         insecureSkipTlsVerify  ? false — skip TLS verification (mutually
#                                  exclusive in practice with caRef/caData,
#                                  but not enforced — kubectl ignores CA
#                                  when insecure is set);
#         namespace ? "default"  — context namespace;
#         user      ? <clusterName> — user entry name (defaults to the
#                                  cluster name; cert variant gets
#                                  "<name>" too);
#       };
#     current ? null (str) — current-context cluster name; null defaults to
#               the FIRST cluster in sorted-key order (deterministic).
#   } -> {
#     config :: attrs — a kubeconfig value:
#       {
#         apiVersion = "v1"; kind = "Config";
#         clusters   = [ { name; cluster = { server; ...tls } } ];
#         users      = [ { name; user = { ...auth-refs } } ];
#         contexts   = [ { name; context = { cluster; user; namespace } } ];
#         "current-context" = <name>;
#       }
#       — ready for (pkgs.formats.yaml {}).generate / builtins.toJSON. All
#         secret material is a REF/placeholder string, materialized at the
#         consumer's activation. Clusters/users/contexts are emitted in
#         sorted-key order (deterministic output).
#     contexts :: [ str ]  — context names (== sorted cluster keys).
#     meta     :: { clusterCount :: int; current :: str; kind = "kubeconfig"; }
#   }
#
# Throws (every message prefixed "kata.kubeconfig.mkKubeconfig: "):
#   - `clusters` missing, not an attrset, or empty;
#   - a clusterSpec missing `server`;
#   - a clusterSpec `auth.kind` not "token"|"clientCert" (or `auth`/`kind`
#     missing);
#   - `current` naming a cluster that is not in `clusters`.
{ lib }:
let
  mkKubeconfig =
    args:
    let
      clusters =
        args.clusters
          or (throw "kata.kubeconfig.mkKubeconfig: `clusters` (attrsOf clusterSpec, non-empty) is required.");

      _clustersChecked =
        if !(builtins.isAttrs clusters) then
          throw "kata.kubeconfig.mkKubeconfig: `clusters` must be an attrset keyed by cluster name — got ${builtins.typeOf clusters}."
        else if clusters == { } then
          throw "kata.kubeconfig.mkKubeconfig: `clusters` must be non-empty — a kubeconfig with zero clusters is meaningless."
        else
          clusters;

      # Deterministic iteration: sorted cluster keys drive every emitted list.
      names = builtins.attrNames _clustersChecked;

      current = args.current or null;

      currentContext =
        if current == null then
          builtins.head names
        else if !(builtins.elem current names) then
          throw "kata.kubeconfig.mkKubeconfig: `current` = '${current}' is not one of the declared clusters (${lib.concatStringsSep ", " names})."
        else
          current;

      # ── per-cluster fact extraction (typed, with throws) ────────────────
      serverFor =
        name: spec:
        spec.server
          or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' is missing `server` (str — \"https://host:port\").");

      userNameFor = name: spec: spec.user or name;
      namespaceFor = spec: spec.namespace or "default";

      # TLS facts: { } | { certificate-authority = ref; }
      #              | { certificate-authority-data = b64; }
      #              | { insecure-skip-tls-verify = true; }
      tlsFor =
        spec:
        let
          insecure = spec.insecureSkipTlsVerify or false;
          caRef = spec.caRef or null;
          caData = spec.caData or null;
        in
        lib.optionalAttrs insecure { insecure-skip-tls-verify = true; }
        // lib.optionalAttrs (caRef != null) { certificate-authority = caRef; }
        // lib.optionalAttrs (caData != null) { certificate-authority-data = caData; };

      # Auth facts → the `user:` block. Refs are PLACEHOLDERS — never a
      # decrypted secret (pure lib, no I/O).
      authUserBlock =
        name: spec:
        let
          auth =
            spec.auth
              or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' is missing `auth` ({ kind = \"token\"|\"clientCert\"; … }).");
          kind =
            auth.kind
              or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' `auth` is missing `kind` (\"token\"|\"clientCert\").");
        in
        if kind == "token" then
          {
            token =
              auth.tokenRef
                or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' token auth is missing `tokenRef` (str — sops placeholder / ref).");
          }
        else if kind == "clientCert" then
          {
            client-certificate-data =
              auth.clientCertRef
                or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' clientCert auth is missing `clientCertRef` (str — ref).");
            client-key-data =
              auth.clientKeyRef
                or (throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' clientCert auth is missing `clientKeyRef` (str — ref).");
          }
        else
          throw "kata.kubeconfig.mkKubeconfig: cluster '${name}' `auth.kind` = '${toString kind}' is unknown — one of \"token\", \"clientCert\".";

      clusterEntries = map (name: {
        inherit name;
        cluster = {
          server = serverFor name _clustersChecked.${name};
        } // tlsFor _clustersChecked.${name};
      }) names;

      userEntries = map (name: {
        name = userNameFor name _clustersChecked.${name};
        user = authUserBlock name _clustersChecked.${name};
      }) names;

      contextEntries = map (name: {
        inherit name;
        context = {
          cluster = name;
          user = userNameFor name _clustersChecked.${name};
          namespace = namespaceFor _clustersChecked.${name};
        };
      }) names;

      config = {
        apiVersion = "v1";
        kind = "Config";
        clusters = clusterEntries;
        users = userEntries;
        contexts = contextEntries;
        "current-context" = currentContext;
      };
    in
    {
      inherit config;
      contexts = map (e: e.name) contextEntries;
      meta = {
        clusterCount = builtins.length names;
        current = currentContext;
        kind = "kubeconfig";
      };
    };
in
{
  inherit mkKubeconfig;
}
