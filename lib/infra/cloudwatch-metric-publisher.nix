# Reusable CloudWatch metric publisher for NixOS AMIs.
#
# Publishes custom CloudWatch metrics from the instance by running a shell
# command on a systemd timer (legacy) or by invoking `cordel metric-publish`
# with a typed source spec (when `useCordel = true`).
#
# Feeds custom CloudWatch alarms such as `AtticQuiescentTriggerDecl` and
# `BuilderQuiescentTriggerDecl` declared in arch-synthesizer. With a 10s
# publish cadence, an alarm with `period=10, evaluation_periods=1` can fire
# within a single publish cycle after the metric goes to zero.
#
# Credentials come from the instance profile -- the AMI consumer must
# ensure the EC2 IAM role has `cloudwatch:PutMetricData` permission.
# (Existing attic + builder pangea-architectures already attach a
# CloudWatch policy to their instance profiles.)
#
# Failures are logged and swallowed: a transient AWS API error never
# triggers a systemd failed-service retry loop that would spam CloudWatch
# with retries or mark the host unhealthy.
#
# Usage (from a NixOS configuration):
#
#   imports = [ (import "${substrate}/lib/infra/cloudwatch-metric-publisher.nix") ];
#
#   pleme.metrics = {
#     enable = true;
#     publishers.atticWriteCount = {
#       namespace = "Pleme/Attic";
#       metricName = "WriteCount";
#       intervalSecs = 10;
#       command = "ss -tHn state established '( sport = :8080 or sport = :443 )' | wc -l | tr -d ' '";
#       region = "us-east-1";
#       unit = "Count";
#     };
#   };
#
# The arch-synthesizer `MetricPublisherDecl` type renders directly into the
# per-publisher attr-set so the AMI config can declare publishers from
# `BuilderQuiescentTriggerDecl::required_publisher()` /
# `AtticQuiescentTriggerDecl::required_publisher()` without duplicating the
# shell command between Rust and Nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.pleme.metrics;

  # Shared awscli package (the AMI almost always has this already; we pin
  # it here so the systemd unit has a deterministic PATH).
  awsCli = "${pkgs.awscli2}/bin/aws";

  publisherType = lib.types.submodule ({name, ...}: {
    options = {
      namespace = lib.mkOption {
        type = lib.types.str;
        description = "CloudWatch metric namespace (e.g. `Pleme/Attic`).";
      };
      metricName = lib.mkOption {
        type = lib.types.str;
        description = "CloudWatch metric name (e.g. `WriteCount`).";
      };
      intervalSecs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = ''
          How often to publish the metric. CloudWatch's minimum period for
          standard metrics is 10s; pairing a 10s publisher with a 10s alarm
          period gives the quickest actionable signal.
        '';
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Legacy shell command whose stdout is the integer metric value.
          Consumed only when `pleme.metrics.useCordel = false` (the
          day-1 default). Prefer `typedSource` when migrating to the
          cordel backend — it's provably integer-valued at seal time.

              ss -tHn state established '( sport = :22 )' | wc -l | tr -d ' '
        '';
      };
      typedSource = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = ''
          Typed CordelMetricSource spec (JSON-serializable attrset). One
          of the following shapes:

            { kind = "TcpConnectionCount"; ports = [ 22 ]; state = "Established"; }
            { kind = "FileAgeSecs"; path = "/var/log/foo"; fallback = 0; }
            { kind = "ProcessCount"; name_pattern = "akeyless-gateway"; }
            { kind = "HttpAccessLogLinesSince"; path = "/var/log/nginx.log"; seconds_ago = 60; }
            { kind = "Constant"; value = 42; }

          Consumed only when `pleme.metrics.useCordel = true`. Overrides
          `command` when both are set.
        '';
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "us-east-1";
        description = "AWS region to publish metrics into.";
      };
      unit = lib.mkOption {
        type = lib.types.str;
        default = "Count";
        description = ''
          CloudWatch metric unit. `Count` matches the typical "how many
          established connections" shape; override for byte counts, etc.
        '';
      };
      dimensions = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = ''
          Optional CloudWatch dimensions to attach to each datapoint as
          `Name=Value,Name=Value`. When empty (the default) the metric is
          published without dimensions, matching the quiescent-trigger
          alarms which aggregate across the whole ASG.
        '';
      };
    };
    config = {
      # Propagate the attr name into a default metricName when the caller
      # didn't override it explicitly -- cheap ergonomics, non-breaking.
    };
  });

  # Render a `bash -c` script that runs `command`, parses the integer, and
  # publishes it. Errors from `aws cloudwatch put-metric-data` are logged
  # but never exit non-zero -- we never want a flaky API call to mark the
  # service as failed and pull the metric stream off-air.
  mkPublishScript = name: p: pkgs.writeShellScript "cloudwatch-publish-${name}" ''
    set -u
    # Capture command stdout; treat any non-integer as 0 so a transient
    # command failure doesn't stall the alarm (0 is the "quiescent" signal
    # which is the conservative safe default for scale-to-zero triggers).
    raw=$(${p.command} 2>/dev/null || echo 0)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      value="$raw"
    else
      echo "[cloudwatch-publish-${name}] non-integer output $(printf %q "$raw"), defaulting to 0" >&2
      value=0
    fi
    echo "[cloudwatch-publish-${name}] ${p.namespace}/${p.metricName}=$value unit=${p.unit} region=${p.region}"
    ${awsCli} cloudwatch put-metric-data \
      --namespace ${lib.escapeShellArg p.namespace} \
      --metric-name ${lib.escapeShellArg p.metricName} \
      --value "$value" \
      --unit ${lib.escapeShellArg p.unit} \
      --region ${lib.escapeShellArg p.region} \
      ${lib.optionalString (p.dimensions != {}) ''--dimensions ${lib.escapeShellArg (lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") p.dimensions))} \''}
      || echo "[cloudwatch-publish-${name}] put-metric-data failed (continuing)" >&2
    exit 0
  '';

  # Cordel path: write a one-shot YAML config file, exec `cordel metric-publish`.
  mkCordelConfigFile = name: p: let
    source =
      if p.typedSource != null
      then p.typedSource
      else {kind = "Constant"; value = 0;}; # defensive fallback
    dimList = lib.mapAttrsToList (k: v: [k v]) p.dimensions;
    yamlPayload = {
      namespace = p.namespace;
      metric_name = p.metricName;
      source = source;
      region = p.region;
      unit = p.unit;
      dimensions = dimList;
      tolerant = true;
    };
  in
    pkgs.writeText "cordel-metric-${name}.yaml" (builtins.toJSON yamlPayload);

  mkCordelPublishService = name: p: {
    description = "Publish ${p.namespace}/${p.metricName} to CloudWatch via cordel";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.cordel}/bin/cordel metric-publish --config ${mkCordelConfigFile name p}";
      Restart = "no";
    };
    path = [pkgs.cordel];
  };

  mkLegacyBashService = name: p: {
    description = "Publish ${p.namespace}/${p.metricName} to CloudWatch";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = toString (mkPublishScript name p);
      # Defensive: never let a failure trigger restart spam. The timer
      # re-runs us on its own schedule; a failed put-metric-data call is
      # already logged and exit 0 ensures systemd treats the unit as clean.
      Restart = "no";
    };
    path = [pkgs.awscli2 pkgs.iproute2 pkgs.coreutils pkgs.gawk pkgs.gnugrep];
  };

  # Dispatcher: pick cordel or legacy per module-level flag.
  mkService = name: p:
    if cfg.useCordel then mkCordelPublishService name p else mkLegacyBashService name p;

  mkTimer = name: p: {
    description = "Timer: publish ${p.namespace}/${p.metricName} every ${toString p.intervalSecs}s";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "${toString p.intervalSecs}s";
      AccuracySec = "1s";
      Unit = "cloudwatch-publish-${name}.service";
    };
  };
in {
  options.pleme.metrics = {
    enable = lib.mkEnableOption "pleme CloudWatch custom metric publisher";

    useCordel = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, each publisher becomes `cordel metric-publish --config
        <yaml>`: typed Rust executor with the MetricSource enum
        (TcpConnectionCount / FileAgeSecs / ProcessCount /
        HttpAccessLogLinesSince / Constant) instead of shelling out to
        `ss` + `aws cloudwatch put-metric-data`. Publishers using the
        new path set `typedSource` instead of `command`.

        Off by default — flip per-AMI when `pkgs.cordel` is available in
        the AMI closure.
      '';
    };

    publishers = lib.mkOption {
      type = lib.types.attrsOf publisherType;
      default = {};
      description = ''
        Named metric publishers. Each generates one systemd service and
        one systemd timer. The attribute name is used to derive the unit
        names: `cloudwatch-publish-<name>.service` /
        `cloudwatch-publish-<name>.timer`.
      '';
      example = lib.literalExpression ''
        {
          atticWriteCount = {
            namespace = "Pleme/Attic";
            metricName = "WriteCount";
            intervalSecs = 10;
            command = "ss -tHn state established '( sport = :8080 or sport = :443 )' | wc -l | tr -d ' '";
          };
          builderActiveSsh = {
            namespace = "Pleme/Builder";
            metricName = "ActiveSshSessions";
            intervalSecs = 10;
            command = "ss -tHn state established '( sport = :22 )' | wc -l | tr -d ' '";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # awscli2 on PATH system-wide so operators can also invoke the same
    # aws commands interactively when debugging the metric stream.
    environment.systemPackages = [pkgs.awscli2];

    systemd.services = lib.mapAttrs'
      (name: p: lib.nameValuePair "cloudwatch-publish-${name}" (mkService name p))
      cfg.publishers;

    systemd.timers = lib.mapAttrs'
      (name: p: lib.nameValuePair "cloudwatch-publish-${name}" (mkTimer name p))
      cfg.publishers;
  };
}
