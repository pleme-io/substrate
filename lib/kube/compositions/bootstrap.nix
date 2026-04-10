# mkBootstrapJob — Bootstrap Job + ServiceAccount + NetworkPolicy.
#
# Pure function — no pkgs dependency.
let
  jobLib = import ../primitives/job.nix;
  sa = import ../primitives/service-account.nix;
  np = import ../primitives/network-policy.nix;
  meta = import ../primitives/metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkBootstrapJob = {
    name,
    namespace,
    image,
    instance ? name,
    command ? [],
    args ? [],
    env ? [],
    envFrom ? [],
    resources ? defs.resources,
    serviceAccount ? { create = true; },
    networkPolicy ? { enabled = true; },
    additionalLabels ? {},
    backoffLimit ? 3,
    ttlSecondsAfterFinished ? 600,
    volumeMounts ? [],
    volumes ? [],
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };
    saName = if (serviceAccount.create or true) then fullname else "default";
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _job = jobLib.mkJob {
      name = fullname; inherit namespace labels image command args env envFrom
              resources backoffLimit ttlSecondsAfterFinished volumeMounts volumes;
      serviceAccountName = saName;
    };

    _serviceAccount = if (serviceAccount.create or true)
      then sa.mkServiceAccount { name = saName; inherit namespace labels; }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
      allowPrometheus = false;
    };

  in {
    job = _job;
    serviceAccount = _serviceAccount;
    networkPolicies = _networkPolicies;
    allResources = o _serviceAccount ++ o _job ++ _networkPolicies;
  };
}
