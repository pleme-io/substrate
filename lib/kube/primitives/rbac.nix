# Kubernetes RBAC builders.
#
# Pure functions — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkClusterRole = {
    name,
    labels ? {},
    annotations ? {},
    rules ? [],
  }: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    metadata = meta.mkMetadata { inherit name labels annotations; };
    inherit rules;
  };

  mkClusterRoleBinding = {
    name,
    labels ? {},
    annotations ? {},
    roleRef,
    subjects ? [],
  }: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = meta.mkMetadata { inherit name labels annotations; };
    inherit roleRef subjects;
  };

  mkRole = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    rules ? [],
  }: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    inherit rules;
  };

  mkRoleBinding = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    roleRef,
    subjects ? [],
  }: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    inherit roleRef subjects;
  };

  # Helper to create a standard operator RBAC set
  mkOperatorRbac = {
    name,
    namespace,
    labels ? {},
    rules,
  }: {
    serviceAccount = (import ./service-account.nix).mkServiceAccount {
      inherit name namespace labels;
    };

    clusterRole = mkClusterRole {
      inherit name labels rules;
    };

    clusterRoleBinding = mkClusterRoleBinding {
      inherit name labels;
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        inherit name;
      };
      subjects = [{
        kind = "ServiceAccount";
        inherit name namespace;
      }];
    };
  };
}
