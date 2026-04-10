# Kubernetes NetworkPolicy builders.
#
# Pure functions — no pkgs dependency.
# Matches the pleme-lib three-policy pattern: deny-all + allow-dns + allow-prometheus.
let
  meta = import ./metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkDenyAll = { name, namespace, labels ? {}, selectorLabels }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = meta.mkMetadata { name = "${name}-deny-all"; inherit namespace labels; };
    spec = {
      podSelector.matchLabels = selectorLabels;
      policyTypes = [ "Ingress" "Egress" ];
    };
  };

  mkAllowDns = { name, namespace, labels ? {}, selectorLabels }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = meta.mkMetadata { name = "${name}-allow-dns"; inherit namespace labels; };
    spec = {
      podSelector.matchLabels = selectorLabels;
      policyTypes = [ "Egress" ];
      egress = [{ ports = [
        { port = 53; protocol = "UDP"; }
        { port = 53; protocol = "TCP"; }
      ]; }];
    };
  };

  mkAllowPrometheus = {
    name, namespace, labels ? {}, selectorLabels,
    monitoringPort ? "http",
    prometheusNamespaces ? defs.networkPolicy.prometheusNamespaces,
  }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = meta.mkMetadata { name = "${name}-allow-prometheus"; inherit namespace labels; };
    spec = {
      podSelector.matchLabels = selectorLabels;
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = map (ns: {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = ns;
        }) prometheusNamespaces;
        ports = [{ port = monitoringPort; protocol = "TCP"; }];
      }];
    };
  };

  mkNetworkPolicy = {
    name, namespace, labels ? {}, selectorLabels,
    policyName,
    policyTypes ? [ "Ingress" ],
    ingress ? [],
    egress ? [],
  }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = meta.mkMetadata { name = "${name}-${policyName}"; inherit namespace labels; };
    spec = {
      podSelector.matchLabels = selectorLabels;
      inherit policyTypes;
    }
    // (if ingress != [] then { inherit ingress; } else {})
    // (if egress != [] then { inherit egress; } else {});
  };

  # Full network policy set matching pleme-lib behavior
  mkNetworkPolicySet = {
    name, namespace, labels ? {}, selectorLabels,
    enabled ? true,
    allowDns ? defs.networkPolicy.allowDns,
    allowPrometheus ? defs.networkPolicy.allowPrometheus,
    monitoringPort ? "http",
    prometheusNamespaces ? defs.networkPolicy.prometheusNamespaces,
    additionalPolicies ? [],
  }: if !enabled then [] else
    [ (mkDenyAll { inherit name namespace labels selectorLabels; }) ]
    ++ (if allowDns then [ (mkAllowDns { inherit name namespace labels selectorLabels; }) ] else [])
    ++ (if allowPrometheus then [ (mkAllowPrometheus { inherit name namespace labels selectorLabels monitoringPort prometheusNamespaces; }) ] else [])
    ++ additionalPolicies;
}
