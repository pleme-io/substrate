# mkCronjobService — CronJob + ServiceAccount + NetworkPolicy.
#
# Pure function — no pkgs dependency.
let
  cjLib = import ../primitives/cronjob.nix;
  sa = import ../primitives/service-account.nix;
  np = import ../primitives/network-policy.nix;
  meta = import ../primitives/metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkCronjobService = {
    name,
    namespace,
    image,
    schedule,
    instance ? name,
    command ? [],
    args ? [],
    env ? [],
    envFrom ? [],
    resources ? defs.resources,
    networkPolicy ? { enabled = true; },
    serviceAccount ? { create = true; },
    additionalLabels ? {},
    concurrencyPolicy ? "Forbid",
    restartPolicy ? "OnFailure",
    activeDeadlineSeconds ? null,
    volumeMounts ? [],
    volumes ? [],
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };
    saName = if (serviceAccount.create or true) then fullname else "default";
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _cronjob = cjLib.mkCronJob {
      name = fullname; inherit namespace labels schedule image command args env envFrom
              resources concurrencyPolicy restartPolicy activeDeadlineSeconds
              volumeMounts volumes;
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
    cronjob = _cronjob;
    serviceAccount = _serviceAccount;
    networkPolicies = _networkPolicies;
    allResources = o _cronjob ++ o _serviceAccount ++ _networkPolicies;
  };
}
