# Reusable AMI build + test pipeline.
#
# Packer orchestrates everything — SSH keys, instance lifecycle, cleanup.
# ami-forge (Rust CLI) is called BY Packer and by the Nix-generated pipeline apps.
# Nix generates all Packer templates as JSON via builtins.toJSON.
#
# Architecture:
#   Nix (this file) generates Packer JSON templates.
#   mkAmiBuildPipeline creates `nix run` apps that invoke `ami-forge pipeline-run`.
#   ami-forge orchestrates: packer build → extract AMI → packer test → cluster-test → promote.
#   On any test failure, ami-forge deregisters the AMI (no bad AMIs in inventory).
#
# Key exports:
#   mkBuildTemplate   — generates build.pkr.json (base NixOS → nixos-rebuild → snapshot)
#   mkTestTemplate    — generates test.pkr.json (boot AMI, run validation)
#                       When testUserData is provided: boots with userdata, runs
#                       `kindling ami-integration-test` (VPN + K3s + kubectl).
#                       When null: runs `kindling ami-test` (11 static checks).
#   mkAmiBuildPipeline — generates nix run apps that call `ami-forge pipeline-run`
#
# Usage:
#   amiBuild = import "${substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
#
#   packages.build-template = amiBuild.mkBuildTemplate { ... };
#   packages.test-template = amiBuild.mkTestTemplate { ... };
#
#   apps = amiBuild.mkAmiBuildPipeline {
#     forgePackage = inputs.ami-forge.packages.${system}.default;
#     buildTemplate = self.packages.${system}.build-template;
#     testTemplate = self.packages.${system}.test-template;
#     ssmParameter = "/my/ssm/param";
#     amiName = "my-ami";
#   };
{ pkgs }:

let
  # Packer is BSL-licensed (unfree)
  unfreePkgs = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "packer" ];
  };

  # Shared NixOS-optimized Packer source defaults
  #
  # shutdown_behavior = "terminate": the builder terminates when its OS shuts
  # down, rather than merely stopping.
  #
  # CORRECTED 2026-07-31 — this comment used to claim the setting prevented
  # orphans "if Packer loses connectivity or the pipeline process is killed".
  # It does NOT, and believing it is why no TTL existed for so long. The
  # setting reacts to an OS shutdown; it has no opinion about the orchestrator.
  # Packer's own "Terminating the source AWS instance" cleanup covers a normal
  # exit INCLUDING a failed build — which is why four consecutive failed bakes
  # were each reaped correctly and the gap stayed invisible — but a KILLED
  # Packer never reaches cleanup, and the instance runs on. Measured: a killed
  # bake stranded i-04baaa6b486fb7fcd (c7i.4xlarge, ~$0.71/hr) until it was
  # found by hand.
  #
  # What makes the setting actually load-bearing is the `user_data`
  # self-destruct timer in mkBuildTemplate: the instance powers ITSELF off at
  # `ttlHours`, and this setting converts that into a termination. The two are
  # one mechanism — do not remove either half.
  nixosSourceDefaults = {
    ssh_username = "root";
    ssh_timeout = "10m";
    shutdown_behavior = "terminate";
    temporary_key_pair_type = "ed25519";
    ssh_clear_authorized_keys = true;
    associate_public_ip_address = true;
  };

  requiredPlugins = {
    amazon = {
      version = ">= 1.3.0";
      source = "github.com/hashicorp/amazon";
    };
  };

  # ── FinOps tagging standard (theory/CAMELOT.md §IV.D) ─────────────
  #
  # The six-key mandatory FinOps tag set every Camelot-owned AWS
  # resource carries — born from a real orphaned EC2 instance (zero
  # tags, only identifiable via a live SSM shell probe). This file
  # already hand-writes `Name` and `ManagedBy` at every `tags`/
  # `run_tags` call site below (and the `ami-forge:purpose` /
  # `ami-forge:ttl-hours` pair, already read back programmatically by
  # ami-forge's own reaper — kept as-is, never replaced); this helper
  # adds exactly the keys that were missing: `Owner`, `Purpose`,
  # `Environment`, `Ephemeral` (+ `TtlHours` when ephemeral). Mirrors
  # pangea-architectures' `Pangea::Architectures::FinopsTags.build` —
  # same six-key standard, same "Name is resource-specific, not
  # produced here" exclusion — so both AWS-resource-creation paths
  # (Pangea-Ruby, Packer/Nix) converge on one tag shape.
  mkFinopsTags = {
    owner ? "platform",
    purpose,
    managedBy ? "pangea",
    environment ? "camelot-dev",
    ephemeral ? false,
    ttlHours ? null,
  }: {
    Owner = owner;
    Purpose = purpose;
    ManagedBy = managedBy;
    Environment = environment;
    Ephemeral = if ephemeral then "true" else "false";
  } // (if ephemeral && ttlHours != null then { TtlHours = toString ttlHours; } else {});

in rec {

  # ── Hardening profile bundle ────────────────────────────────
  # Re-export so consumers can build their own provisioner scripts
  # without a separate import. See lib/infra/hardening-profiles/
  # for the underlying yaml files + helper.
  hardeningProfiles = import ./hardening-profiles { inherit pkgs; };

  # ── Nix build parallelism, sized to the builder instance ─────
  #
  # Every mkBuildTemplate provisioner runs `nixos-rebuild switch` on a
  # box that may have no reachable substituter (rio's Attic cache is
  # Tailscale MagicDNS-only — confirmed unreachable from a Camelot-VPC
  # builder via a live SSM probe, 2026-07-16), meaning a fully-cold
  # from-source build of the whole flake closure is a real, expected
  # path, not an edge case. nix's own default (max-jobs=auto == nproc,
  # cores=0 == unlimited per job) lets every core start its own
  # concurrent derivation build — fine for small closures, but for a
  # closure with dozens of heavy Rust crates (several large AWS SDK
  # crates, async-graphql, tatara-lisp, the project's own binaries) it
  # blows past available RAM and the box disconnects mid-build (the
  # portao-camelot-ami-build incident this table exists to prevent a
  # repeat of: 16-way-parallel on a 32GB c7i.4xlarge, 27 minutes in,
  # SSH dropped). The fix already landed once by hand as a hardcoded
  # `--option max-jobs 1 --option cores 1` in kindling-profiles — the
  # exact fleet-known-good pangea-operator CI value for a MUCH smaller
  # runner. That's safe everywhere but leaves most of a bigger box's
  # real capacity idle. This table auto-sizes instead: known-safe on a
  # box we've never measured, and not needlessly serial on one we have
  # real headroom on.
  #
  # perJobRamGb is a heuristic, not a measured ceiling — pangea-
  # operator's own postmortem (release.yml) found even 2 CONCURRENT
  # native compiles OOM'd a smaller runner, well under what a naive
  # "assume 2GB/job" division would predict was safe. Defaulting to
  # 4GB/job here is deliberately conservative given that lesson; pass
  # a lower value only once a specific crate graph's real peak RSS has
  # actually been measured, not by guessing tighter.
  #
  # ── HOW TO MEASURE IT, and how NOT to (corrected 2026-07-31) ────────
  # This used to advise `/usr/bin/time -v` around a cold build. That
  # measures NOTHING here. `nixos-rebuild` talks to nix-daemon, so every
  # builder process is a child of the DAEMON, not of the timed client —
  # `getrusage(RUSAGE_CHILDREN)` on the `nix` client returns the client's
  # own footprint, which is a few hundred MB regardless of how much a
  # compile actually used. Anyone following that advice would have
  # measured a number that looks plausible and means nothing.
  #
  # Worse, it measures the wrong STATISTIC even in principle. Sizing
  # max-jobs needs the per-DERIVATION peak, specifically the top-N
  # concurrent sum; a whole-invocation peak cannot be divided back into
  # one.
  #
  # There is currently no supported way to get per-derivation peak RSS
  # out of nix: `nix build --json` carries store paths and cache status,
  # `nix log` is builder stdout, and the post-build-hook contract is
  # exactly DRV_PATH + OUT_PATHS + NIX_CONFIG (the hook also runs AFTER
  # the builder is reaped, so getrusage is unavailable to it). nix's
  # per-build cgroup would expose memory.peak, but it needs the `cgroups`
  # experimental feature — not enabled on these builders — and nix reads
  # only cpu.stat from it, then destroys the cgroup before the hook runs.
  #
  # So the honest status is: this number is UNMEASURED, and the tooling
  # to measure it does not exist yet. Building that sampler is the
  # prerequisite for turning perJobRamGb into a lookup against real data
  # instead of a judgement call. Until then, raising it is the safe
  # direction and lowering it needs evidence this file cannot yet give
  # you.
  #
  # ── AND IT IS NOT max-jobs ALONE ───────────────────────────────────
  # Peak memory tracks maxJobs * cores, not maxJobs. Measured the hard
  # way 2026-07-31: an AMI bake was "fixed" by moving 8 jobs x 2 cores to
  # 4 jobs x 4 cores. Both products are 16, so total concurrent compilers
  # — and peak memory — were IDENTICAL, and the same translation unit
  # died at the same point on the retry. When sizing for memory, reason
  # about the product.
  amiBuilderInstanceSpecs = {
    "t3.small"    = { vcpu = 2;  ramGb = 2;  };
    "t3.medium"   = { vcpu = 2;  ramGb = 4;  };
    "t3.large"    = { vcpu = 2;  ramGb = 8;  };
    "t3.xlarge"   = { vcpu = 4;  ramGb = 16; };
    "c7i.xlarge"  = { vcpu = 4;  ramGb = 8;  };
    "c7i.2xlarge" = { vcpu = 8;  ramGb = 16; };
    "c7i.4xlarge" = { vcpu = 16; ramGb = 32; };
    "c7i.8xlarge" = { vcpu = 32; ramGb = 64; };
  };

  # Returns the literal `--option max-jobs N --option cores M` string
  # to interpolate into a `nixos-rebuild switch` invocation, sized to
  # `instanceType`. Unknown instance types fall back to the
  # fleet-proven pangea-operator floor (max-jobs=1, cores=1) rather
  # than guessing — an unrecognized type is exactly the case where
  # this table has no evidence to size from, so it defers to the
  # known-safe value instead of extrapolating.
  nixBuildOptsFor = { instanceType, perJobRamGb ? 4 }:
    let
      spec = amiBuilderInstanceSpecs.${instanceType} or null;
      maxJobs =
        if spec == null then 1
        else pkgs.lib.max 1 (pkgs.lib.min spec.vcpu (spec.ramGb / perJobRamGb));
      cores =
        if spec == null then 1
        else pkgs.lib.max 1 (spec.vcpu / maxJobs);
    in "--option max-jobs ${toString maxJobs} --option cores ${toString cores}";

  # The FIRST `nixos-rebuild switch` every mkBuildTemplate provisioner runs
  # is unavoidably raw shell, not a `kindling ami-build` call — `kindling`
  # itself is one of the packages THIS rebuild installs, so it doesn't
  # exist on the box's PATH yet (the chicken-and-egg every consumer's own
  # `--skip-rebuild` flag on its SECOND `kindling ami-build` step already
  # assumes). What was genuinely a "solve once" violation is that six
  # kindling-profiles call sites each hand-typed their own copy of this
  # ~230-character Attic-conditional string — one had drifted to
  # hand-append `--option max-jobs 1 --option cores 1`, the other five
  # didn't, an inconsistency nixBuildOptsFor's $NIX_BUILD_OPTS (env var,
  # already exported by mkBuildTemplate/mkLayerTemplate below) now makes
  # structurally impossible to drift on. Callers interpolate this ONE
  # string instead of retyping the conditional; $FLAKE_REF/$GITHUB_TOKEN/
  # $ATTIC_URL/$NIX_BUILD_OPTS all come from the provisioner's own
  # environment_vars.
  # $GITHUB_TOKEN is frequently EMPTY (unset locally, or the operator's
  # token is broken/expired — a real 2026-07-16 incident: every one of
  # three live GitHub credentials independently failed with an
  # authenticated-only fault, while the same fetches worked instantly
  # unauthenticated, because kindling-profiles/blackmatter are both
  # PUBLIC repos). Passing `--option access-tokens github.com=` with an
  # empty value still emits a populated (if blank) Authorization header —
  # NOT the same as omitting the flag — and that's enough to route the
  # request through GitHub's authenticated-request path even when no
  # credential is actually needed or working. Emit the flag only when a
  # non-empty token is present so a public-repo fetch never depends on
  # having a working token at all.
  nixosRebuildSwitchStep =
    ''ACCESS_TOKENS_OPT=""; [ -n "$GITHUB_TOKEN" ] && ACCESS_TOKENS_OPT="--option access-tokens github.com=$GITHUB_TOKEN"; if [ -n "$ATTIC_URL" ]; then echo "Using binary cache (sui): $ATTIC_URL"; nixos-rebuild switch --flake $FLAKE_REF $ACCESS_TOKENS_OPT --option extra-substituters "$ATTIC_URL" --option require-sigs false $NIX_BUILD_OPTS; else nixos-rebuild switch --flake $FLAKE_REF $ACCESS_TOKENS_OPT $NIX_BUILD_OPTS; fi'';

  # ── Shared app wrapper ───────────────────────────────────────────
  #
  # Every `nix run` app below shares one shape: export PATH, then run a
  # script. GC-root protection for the long-running (~15-30min) pipeline
  # apps — the real fix for a live 2026-07-16 incident where a Packer
  # template's store path was collected mid-run — lives in **pure Rust**,
  # not here: `ami-forge`'s own `GcRootGuard` (pipeline.rs/multi_layer.rs)
  # holds an explicit `nix-store --add-root` for every template/config
  # path it's given, for its own process's full lifetime, via Drop. This
  # keeps the Nix layer as pure declaration + YAML config (the shikumi
  # pattern already documented above) and the orchestration/lifecycle
  # logic — including its safety mechanisms — in the typed Rust binary
  # that actually owns the pipeline. Full analysis: theory/AMI-FORGE.md.
  mkAmiApp = {
    name,
    script,
    forgePackage,
    awsProfile ? null,
    extraBinaries ? [],
  }: {
    type = "app";
    program = toString (pkgs.writeShellScript name ''
      set -euo pipefail
      export PATH="${pkgs.lib.makeBinPath ([ forgePackage unfreePkgs.packer pkgs.awscli2 ] ++ extraBinaries)}:$PATH"
      ${pkgs.lib.optionalString (awsProfile != null) ''export AWS_PROFILE="${awsProfile}"''}
      ${script}
    '');
  };

  # ── Cluster Test Config ──────────────────────────────────────
  # Generates a YAML config file (JSON is valid YAML) describing the
  # multi-node cluster topology for ami-forge cluster-test.
  mkClusterTestConfig = {
    nodes,
    instanceType ? "c7i.xlarge",
    timeout ? 600,
    k3sToken ? "ami-forge-cluster-test-token",
    clusterName ? "cluster-test",
    minReadyNodes ? (builtins.length nodes),
    minVpnHandshakes ? 2,
    kubectlFromClient ? true,
    # IAM instance profile name for EC2 tag-based state reporting.
    # Deployed via Pangea (one-time IaC). Instances tag themselves with
    # BootstrapPhase during kindling-init, orchestrator polls tags.
    instanceProfileName ? null,
  }: pkgs.writeText "cluster-test-config.yaml" (builtins.toJSON ({
    inherit timeout;
    instance_type = instanceType;
    k3s_token = k3sToken;
    cluster_name = clusterName;
    nodes = builtins.map (n: {
      name = n.name;
      role = n.role;
      vpn_address = n.vpn_address;
      node_index = n.node_index;
      cluster_init = n.cluster_init or false;
    }) nodes;
    checks = {
      min_ready_nodes = minReadyNodes;
      min_vpn_handshakes = minVpnHandshakes;
      kubectl_from_client = kubectlFromClient;
    };
  } // (if instanceProfileName != null then {
    instance_profile_name = instanceProfileName;
  } else {})));

  # ── Build Template ──────────────────────────────────────────
  # Generates build.pkr.json — builds a NixOS AMI from a base image.
  # Packer handles SSH, instance lifecycle, and cleanup.
  mkBuildTemplate = {
    name ? "build-template.pkr.json",
    amiName,
    flakeRef,
    sourceAmiFilter ? { name = "nixos/25.*"; architecture = "x86_64"; },
    sourceAmiOwners ? [ "427812963091" ],
    instanceType ? "c7i.4xlarge",
    volumeSize ? 30,
    region ? "us-east-1",
    iops ? 8000,
    throughput ? 500,
    provisionerScript ? [],
    extraVariables ? {},
    extraTags ? {},
    extraEnvironmentVars ? [],
    # FinOps tagging standard (theory/CAMELOT.md §IV.D) — see
    # mkFinopsTags above. Sensible defaults; override per call site
    # when the resource has a real owner/purpose/environment.
    owner ? "platform",
    purpose ? "NixOS base AMI build for ${amiName}",
    environment ? "camelot-dev",
    # List of profile names to apply via `kindling harden` after the
    # main provisionerScript. Accepts the same stack keys as the
    # hardening-profiles bundle: "base", "hardened", "ami-full",
    # "cis-level-1". Pass `null` (default) to skip — some pipelines
    # handle hardening themselves inside provisionerScript.
    hardeningStack ? null,
    # When true, a Degraded hardening report also fails the build.
    # Default `false` matches `kindling harden`'s exit semantics.
    hardeningStrict ? false,
    # ── SELF-DESTRUCT TTL — the orphan backstop ──────────────────────
    # Hours after boot at which the builder powers ITSELF off. Combined
    # with `shutdown_behavior = "terminate"` (nixosSourceDefaults) that
    # is a self-termination, so an abandoned builder cannot outlive this
    # no matter what happened to the orchestrator.
    #
    # ONE field drives THREE things — the `TtlHours` FinOps tag, the
    # `ami-forge:ttl-hours` run tag, and the actual poweroff timer — so
    # the declared TTL and the enforced TTL are the same number by
    # construction. They were previously three independent literals, and
    # the two tags claimed a 4h TTL that nothing implemented.
    #
    # 4h is generous against observed build times (~40min for a full
    # Rust closure on a c7i.4xlarge); it exists to bound abandonment,
    # not to bound a slow build. Raise it for a genuinely longer bake
    # rather than removing it.
    ttlHours ? 4,
    # ── BINARY-CACHE SUBSTITUTER (sui) ────────────────────────────────
    # A cache URL the builder substitutes from, e.g. an in-VPC sui endpoint.
    #
    # WHY THIS EXISTS — measured, not speculative. A bake with NO substituter
    # substituted 604 paths and BUILT 1304 FROM SOURCE, including
    # `llvm-static-x86_64-unknown-linux-musl` and `rustc-static-…-musl`: a
    # whole static Rust toolchain compiled from scratch because nothing serves
    # it. That LLVM build failed after 1h32m (`ninja: build stopped`, not an
    # OOM), which cascaded through rustc-static → rustc-wrapper → the entire
    # system closure. A warm cache is not an optimisation here; it is the
    # difference between a bake that completes and one that cannot.
    #
    # ATTIC IS RETIRED FLEET-WIDE; SUI HAS TAKEN OVER EVERY ATTIC FUNCTION.
    # The variable that carries this to the provisioner is still named
    # `attic_url`, deliberately: ami-forge's Rust side and the multi-layer
    # templates both read that name, and renaming it would be a cross-repo
    # break for zero behavioural gain. The NAME is legacy; the BACKEND is sui.
    # (MODULARIZE, DON'T DELETE — the ephemeral-attic bootstrap in
    # `mkAmiBuildPipeline`'s `atticSsm` stays intact and simply goes unused.)
    #
    # Empty (the default) means "no substituter", which is the from-source
    # behaviour described above — correct only for a builder that has nothing
    # to pull from.
    substituterUrl ? "",
    # RAM budget per concurrent nix job, feeding `nixBuildOptsFor`'s
    # max-jobs/cores sizing. Default 4 keeps every existing caller identical.
    #
    # RAISE IT for a closure containing a memory-hungry C++ build. Measured
    # 2026-07-31: on a c7i.4xlarge (16 vCPU / 32 GB) the default yields
    # maxJobs = min(16, 32/4) = 8 with cores = 2 — eight concurrent
    # derivations against a 4 GB/job budget on a 32 GB box, i.e. ZERO headroom
    # for the OS and page cache. A `llvm-static-…-musl` build in that closure
    # died with `ninja: build stopped: subcommand failed` after 1h32m, which is
    # what an OOM-killed compiler looks like from nix's side: the kernel's
    # OOM message goes to dmesg, never into the build log, so there is no
    # "out of memory" string to grep for. LLVM translation units routinely
    # exceed 4 GB on their own.
    #
    # perJobRamGb = 8 on that box gives maxJobs = 4, cores = 4 — half the
    # concurrency, double the per-job budget, and the same 16 cores in use.
    # The file's own guidance (see `amiBuilderInstanceSpecs`) is that lowering
    # this needs a measurement first; raising it is the conservative direction.
    perJobRamGb ? 4,
  }: let
    hardeningProfiles = import ./hardening-profiles { inherit pkgs; };
    # Resolve a stack name ("base", "hardened", "ami-full",
    # "cis-level-1") into its ordered list of profile-name strings.
    # ami-full expands to base + hardened + ami-snapshot; cis-level-1
    # is standalone. The resolved names are passed to mkHardenStep
    # as `stackNames` so the profile YAML is inlined into the Packer
    # provisioner (remote /nix/store paths don't resolve otherwise).
    stackNameList = {
      base = [ "base" ];
      hardened = [ "base" "hardened" ];
      ami-full = [ "base" "hardened" "ami-snapshot" ];
      cis-level-1 = [ "cis-level-1" ];
    };
    hardeningSteps =
      if hardeningStack == null
      then []
      else hardeningProfiles.mkHardenStep {
        stackNames = stackNameList.${hardeningStack};
        strict = hardeningStrict;
      };
    fullProvisioner = provisionerScript ++ hardeningSteps;
    template = {
      variable = {
        ami_name = { type = "string"; default = amiName; };
        region = { type = "string"; default = region; };
        instance_type = { type = "string"; default = instanceType; };
        volume_size = { type = "number"; default = volumeSize; };
        github_token = { type = "string"; default = ""; sensitive = true; };
        flake_ref = { type = "string"; default = flakeRef; };
        # The builder's binary-cache substituter. Historically an ephemeral
        # attic instance (hence the name, kept so ami-forge's Rust side and the
        # multi-layer templates keep working unchanged); `substituterUrl` now
        # lets a caller point it at SUI, which has taken over every attic
        # function fleet-wide.
        attic_url = { type = "string"; default = substituterUrl; };
      } // extraVariables;

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.nixos = nixosSourceDefaults // {
        ami_name = "\${var.ami_name}";
        region = "\${var.region}";
        instance_type = "\${var.instance_type}";
        source_ami_filter = {
          filters = {
            virtualization-type = "hvm";
            root-device-type = "ebs";
          } // sourceAmiFilter;
          owners = sourceAmiOwners;
          most_recent = true;
        };
        launch_block_device_mappings = [{
          device_name = "/dev/xvda";
          volume_size = "\${var.volume_size}";
          volume_type = "gp3";
          inherit iops throughput;
          delete_on_termination = true;
        }];
        force_deregister = true;
        force_delete_snapshot = true;
        tags = {
          Name = "\${var.ami_name}";
          ManagedBy = "pangea";
          BuildTimestamp = "{{timestamp}}";
          SourceFlake = "\${var.flake_ref}";
        } // mkFinopsTags { inherit owner purpose environment; ephemeral = false; } // extraTags;
        run_tags = {
          Name = "ami-forge-builder";
          ManagedBy = "pangea";
          "ami-forge:purpose" = "ami-build";
          "ami-forge:ttl-hours" = toString ttlHours;
        } // mkFinopsTags { inherit owner purpose environment ttlHours; ephemeral = true; };

        # ── THE SELF-DESTRUCT ────────────────────────────────────────
        # Arms a one-shot systemd timer at first boot. On expiry the
        # instance powers itself off, and `shutdown_behavior =
        # "terminate"` turns that into a termination — so an abandoned
        # builder reaps itself with no external watcher, no credentials
        # on the instance, and no dependency on the workstation still
        # being alive.
        #
        # WHY THIS EXISTS (measured 2026-07-31, not theoretical). The
        # `shutdown_behavior` comment above used to claim it already
        # prevented orphans "if Packer loses connectivity or the
        # pipeline process is killed". That was FALSE and is corrected
        # there now: `shutdown_behavior` fires only when the OS shuts
        # down, and Packer's own "Terminating the source AWS instance"
        # cleanup runs only on a normal exit. A KILLED Packer therefore
        # strands the builder. It happened: i-04baaa6b486fb7fcd, a
        # c7i.4xlarge, ran unattended at ~$0.71/hr until it was found by
        # hand. Four earlier bakes that FAILED were all reaped correctly
        # by Packer — which is exactly why the gap stayed invisible.
        #
        # NO SHELL, honestly qualified: this is user_data on a BARE base
        # AMI, before any of our closure exists — there is no
        # tatara-script, no kindling, not even git on PATH yet (an
        # earlier attempt to run `git config` at this stage died with
        # exit 127). A two-line boot script is the 1-3 line glue the
        # rule permits, and `systemd-run --on-active` is the platform's
        # own timer primitive rather than a hand-rolled sleep loop.
        user_data = ''
          #!/bin/sh
          systemd-run --on-active=${toString ttlHours}h --unit=ami-forge-ttl-guard systemctl poweroff
        '';
      };

      build = [{
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner =
          [{
            shell = {
              inline = fullProvisioner;
              environment_vars = [
                "GITHUB_TOKEN=\${var.github_token}"
                "FLAKE_REF=\${var.flake_ref}"
                "ATTIC_URL=\${var.attic_url}"
                # Auto-sized nix build parallelism for THIS template's
                # instanceType — see nixBuildOptsFor above. Every
                # provisionerScript should interpolate $NIX_BUILD_OPTS
                # into its `nixos-rebuild switch` invocation instead of
                # a hand-typed --option max-jobs/--option cores literal,
                # so the safe value tracks the instance the template
                # actually declares rather than drifting per-consumer.
                "NIX_BUILD_OPTS=${nixBuildOptsFor { inherit instanceType perJobRamGb; }}"
              ] ++ extraEnvironmentVars;
              # `nixos-rebuild switch` (the standard first step of
              # fullProvisioner/provisionerScript for every mkBuildTemplate
              # consumer) CAN legitimately restart networking/sshd when the
              # activation touches those units, dropping Packer's SSH
              # session mid-script — kept as defensive hardening for that
              # case. Correction (2026-07-16, same day): the original
              # comment here cited the portao-camelot-ami-build 27-minute
              # disconnect as "confirmed live" evidence for THIS failure
              # mode, but a direct read of that build's own log shows the
              # disconnect landed mid-way through `nixos-rebuild switch`'s
              # BUILD phase (compiling rust_pleme-kindling-0.3.0.drv, one
              # of the last derivations in the graph) — well before any
              # activation step runs, so no networking/sshd restart could
              # have occurred yet. That incident's real cause was nix's
              # unconstrained max-jobs=auto running ~16 heavy Rust crate
              # builds concurrently on the c7i.4xlarge builder with no
              # substituter cache reachable (rio's Attic is Tailscale-only,
              # unreachable from that VPC), OOM-adjacent resource
              # exhaustion — fixed via nixBuildOptsFor below (auto-sized
              # max-jobs/cores), not by this setting. Leaving
              # expect_disconnect=true in place regardless — it is still
              # sound defensive coverage for a genuine, separate failure
              # mode, just not what actually happened here.
              expect_disconnect = true;
            };
          }];
        post-processor.manifest = {
          output = "packer-manifest.json";
          strip_path = true;
        };
      }];
    };
  in pkgs.writeText name (builtins.toJSON template);

  # ── Test Template ───────────────────────────────────────────
  # Generates test.pkr.json — boots from built AMI, runs checks.
  # skip_create_ami = true: no snapshot, just validate.
  # Packer handles SSH natively — no manual key management.
  mkTestTemplate = {
    name ? "test-template.pkr.json",
    region ? "us-east-1",
    instanceType ? "t3.medium",
    # Test userdata (JSON string) — injected as EC2 user_data.
    # Provides a minimal cluster-config for kindling-init to bootstrap.
    # If null, no userdata is injected (basic boot check only).
    testUserData ? null,
    # Commands to run on the test instance.
    # When testUserData is set: defaults to integration test (waits for kindling-init + validates VPN/K3s/kubectl).
    # When null: defaults to static AMI checks (binary presence, services, no stale state).
    testScript ? (if testUserData != null then [
      "export PATH=/run/current-system/sw/bin:$PATH"
      "kindling ami-integration-test --timeout 600"
    ] else [
      "kindling ami-test"
    ]),
    # FinOps tagging standard (theory/CAMELOT.md §IV.D) — see
    # mkFinopsTags above.
    owner ? "platform",
    purpose ? "AMI validation test instance",
    environment ? "camelot-dev",
  }: let
    template = {
      variable = {
        source_ami = { type = "string"; };
        region = { type = "string"; default = region; };
      };

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.test = nixosSourceDefaults // {
        ami_name = "ami-forge-test-{{timestamp}}";
        region = "\${var.region}";
        instance_type = instanceType;
        source_ami = "\${var.source_ami}";
        skip_create_ami = true;
        run_tags = {
          Name = "ami-forge-test";
          ManagedBy = "pangea";
          "ami-forge:purpose" = "ami-test";
          "ami-forge:ttl-hours" = "2";
        } // mkFinopsTags { inherit owner purpose environment; ephemeral = true; ttlHours = 2; };
      } // (if testUserData != null then {
        user_data = testUserData;
      } else {});

      build = [{
        sources = [ "source.amazon-ebs.test" ];
        provisioner.shell = {
          inline = testScript;
        };
      }];
    };
  in pkgs.writeText name (builtins.toJSON template);

  # ── Layer Template (for multi-layer AMI pipelines) ──────────────
  # Generalized template builder supporting both source AMI filter mode
  # (Layer 1 — finds base NixOS) and explicit source AMI mode (Layers 2+).
  mkLayerTemplate = {
    name ? "layer.pkr.json",
    amiName,
    provisionerScript,
    # When false: uses sourceAmiFilter to find base AMI (like mkBuildTemplate)
    # When true: uses source_ami variable (like mkTestTemplate)
    sourceAmiVariable ? false,
    sourceAmiFilter ? { name = "nixos/25.*"; architecture = "x86_64"; },
    sourceAmiOwners ? [ "427812963091" ],
    instanceType ? "c7i.4xlarge",
    volumeSize ? 30,
    region ? "us-east-1",
    # ── Two parameters mkBuildTemplate has and this did NOT ──────────────
    # A multi-layer caller that passed either got it silently ignored: the
    # rendered template used the hardcoded defaults regardless, so raising
    # perJobRamGb for a memory-hungry layer did nothing and pointing a layer at
    # a substituter did nothing. Silent, because an unused argument in a Nix
    # function signature is not an error — the caller looks correct and the
    # output is unchanged.
    #
    # Defaults match the sibling exactly, so every existing caller renders
    # byte-identically. What changes is that passing them now has an effect.
    perJobRamGb ? 4,
    substituterUrl ? "",
    iops ? 8000,
    throughput ? 500,
    extraVariables ? {},
    extraEnvironmentVars ? [],
    extraTags ? {},
    skipCreateAmi ? false,
    # FinOps tagging standard (theory/CAMELOT.md §IV.D) — see
    # mkFinopsTags above.
    owner ? "platform",
    purpose ? "NixOS layered AMI build for ${amiName}",
    environment ? "camelot-dev",
  }: let
    template = {
      variable = {
        ami_name = { type = "string"; default = amiName; };
        region = { type = "string"; default = region; };
        instance_type = { type = "string"; default = instanceType; };
        volume_size = { type = "number"; default = volumeSize; };
        github_token = { type = "string"; default = ""; sensitive = true; };
        # Named attic_url for ami-forge wire compatibility; the VALUE is now
        # whatever substituterUrl supplies (sui, per the fleet-wide attic
        # retirement) rather than a hardcoded empty string.
        attic_url = { type = "string"; default = substituterUrl; };
      } // (if sourceAmiVariable then {
        source_ami = { type = "string"; };
      } else {}) // extraVariables;

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.nixos = nixosSourceDefaults // {
        ami_name = "\${var.ami_name}";
        region = "\${var.region}";
        instance_type = "\${var.instance_type}";
      } // (if sourceAmiVariable then {
        source_ami = "\${var.source_ami}";
      } else {
        source_ami_filter = {
          filters = {
            virtualization-type = "hvm";
            root-device-type = "ebs";
          } // sourceAmiFilter;
          owners = sourceAmiOwners;
          most_recent = true;
        };
      }) // {
        launch_block_device_mappings = [{
          device_name = "/dev/xvda";
          volume_size = "\${var.volume_size}";
          volume_type = "gp3";
          inherit iops throughput;
          delete_on_termination = true;
        }];
        skip_create_ami = skipCreateAmi;
        force_deregister = !skipCreateAmi;
        force_delete_snapshot = !skipCreateAmi;
        tags = {
          Name = "\${var.ami_name}";
          ManagedBy = "pangea";
          BuildTimestamp = "{{timestamp}}";
        } // mkFinopsTags { inherit owner purpose environment; ephemeral = false; } // extraTags;
        run_tags = {
          Name = "ami-forge-layer-builder";
          ManagedBy = "pangea";
          "ami-forge:purpose" = "layer-build";
          "ami-forge:ttl-hours" = "4";
        } // mkFinopsTags { inherit owner purpose environment; ephemeral = true; ttlHours = 4; };
      };

      build = [({
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner = [{
          shell = {
            inline = provisionerScript;
            environment_vars = [
              "GITHUB_TOKEN=\${var.github_token}"
              "ATTIC_URL=\${var.attic_url}"
              # See mkBuildTemplate's identical field — same nixosRebuildSwitchStep
              # is usable here for any layer whose provisionerScript runs its own
              # `nixos-rebuild switch`.
              "NIX_BUILD_OPTS=${nixBuildOptsFor { inherit instanceType perJobRamGb; }}"
            ] ++ extraEnvironmentVars;
            # See mkBuildTemplate's identical field for why: a caller-supplied
            # provisionerScript that runs `nixos-rebuild switch` can
            # legitimately disconnect Packer's SSH session mid-activation.
            expect_disconnect = true;
          };
        }];
      } // (if !skipCreateAmi then {
        post-processor.manifest = {
          output = "packer-manifest.json";
          strip_path = true;
        };
      } else {}))];
    };
  in pkgs.writeText name (builtins.toJSON template);

  # ── Pipeline Apps ───────────────────────────────────────────
  # Generates nix run apps that orchestrate: packer build → packer test → promote
  # Configuration follows the shikumi pattern: Nix option → YAML config → Rust reads config.
  mkAmiBuildPipeline = {
    forgePackage,
    buildTemplate,
    testTemplate,
    ssmParameter,
    amiName,
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    skipClusterTest ? false,
    clusterTestConfig ? null,
    clusterTestInstanceType ? "c7i.xlarge",
    clusterTestTimeout ? 480,
    # Attic ephemeral cache (optional). When set, ami-forge boots an Attic
    # instance before building, uses it as a substituter, snapshots after.
    atticSsm ? null,          # SSM parameter with Attic AMI ID
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
    # When true, ami-forge adds a public LaunchPermission (Group=all)
    # after promoting to SSM. Lets any AWS account launch the AMI
    # without per-account shares. Use only for AMIs known to carry no
    # secrets — privkeys must arrive at runtime (e.g. SSM, IMDSv2).
    makePublic ? false,
  }: let
    # Generate pipeline config as YAML via Nix (JSON is valid YAML)
    pipelineConfig = pkgs.writeText "pipeline-config.yaml" (builtins.toJSON ({
      build_template = "${buildTemplate}";
      test_template = "${testTemplate}";
      ssm = ssmParameter;
      ami_name = amiName;
      inherit region;
      skip_cluster_test = skipClusterTest;
      cluster_test_instance_type = clusterTestInstanceType;
      cluster_test_timeout = clusterTestTimeout;
      make_public = makePublic;
    } // (if skipClusterTest || clusterTestConfig == null then {}
      else { cluster_test = { config = "${clusterTestConfig}"; }; })
    // (if atticSsm == null then {}
      else { attic = {
        ssm = atticSsm;
        instance_type = atticInstanceType;
        cache_name = atticCacheName;
      }; })));

    app = name: script: mkAmiApp {
      inherit name script forgePackage awsProfile extraBinaries;
    };

  in {
    # Build AMI: build → test → promote (ONE pipeline, always tested).
    # All orchestration logic — including the GC-root guard — lives in
    # ami-forge's Rust (pipeline-run); this is a plain declarative call.
    ami-build = app "ami-build" ''
      ami-forge pipeline-run --config "${pipelineConfig}"
    '';

    # Test existing AMI from SSM (re-run tests without rebuilding) — routed
    # through ami-forge's own `test-ami` subcommand (not raw packer calls)
    # so the SAME GC-root guard protects this path too.
    ami-test = app "ami-test" ''
      AMI_ID=$(aws ssm get-parameter --name "${ssmParameter}" --region "${region}" --query 'Parameter.Value' --output text)
      ami-forge test-ami --template "${testTemplate}" --source-ami "$AMI_ID" --region "${region}"
    '';

    # Show AMI status.
    ami-status = app "ami-status" ''
      ami-forge status --ssm "${ssmParameter}" --region "${region}"
    '';
  };

  # ── Multi-Layer Pipeline Apps ────────────────────────────────────
  # Generates nix run apps for multi-layer AMI build pipeline.
  # Each layer produces an intermediate AMI checkpointed in SSM.
  mkMultiLayerPipeline = {
    forgePackage,
    layers,           # list of { template, name, ssmParameter, fingerprintInputs ? [] }
    testLayers ? [],  # list of { template, name }
    promoteSsm,
    amiName,
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    atticSsm ? null,
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
  }: let
    pipelineConfig = pkgs.writeText "multi-layer-pipeline-config.yaml" (builtins.toJSON ({
      layers = map (l: {
        template = "${l.template}";
        name = l.name;
        ssm_parameter = l.ssmParameter;
        fingerprint_inputs = l.fingerprintInputs or [];
      }) layers;
      test_layers = map (t: {
        template = "${t.template}";
        name = t.name;
      }) testLayers;
      promote_ssm = promoteSsm;
      ami_name = amiName;
      inherit region;
    } // (if atticSsm == null then {} else {
      attic = {
        ssm = atticSsm;
        instance_type = atticInstanceType;
        cache_name = atticCacheName;
      };
    })));

    app = name: script: mkAmiApp {
      inherit name script forgePackage awsProfile extraBinaries;
    };
  in {
    # GC-root guard for every layer/test-layer template + the config
    # itself lives in ami-forge's `multi-layer-run` (GcRootGuard) — see
    # mkAmiApp's own comment.
    ami-build = app "ami-build-layered" ''
      ami-forge multi-layer-run --config "${pipelineConfig}"
    '';

    ami-status = app "ami-status-layered" ''
      echo "Layer status:"
      ${builtins.concatStringsSep "\n" (map (l: ''
        echo -n "  ${l.name}: "
        aws ssm get-parameter --name "${l.ssmParameter}" --region "${region}" --query 'Parameter.Value' --output text 2>/dev/null || echo "not built"
      '') layers)}
      echo -n "  promoted: "
      aws ssm get-parameter --name "${promoteSsm}" --region "${region}" --query 'Parameter.Value' --output text 2>/dev/null || echo "not promoted"
    '';
  };

  # ── Multi-Arch AMI Pipelines ──────────────────────────────────
  # The common case: same AMI shape, different CPU architectures (and
  # whatever arch-dependent knobs fall out — source AMI SSM path,
  # Packer build template, AMI name prefix). Instead of every caller
  # copy-pasting mkAmiBuildPipeline once per arch, declare the list
  # once and get symmetrical nix-run apps out.
  #
  # Input:  archs = [ "aarch64" "x86_64" ... ];
  #         anything produced "for this arch" is supplied as a
  #         function `a -> …`.
  # Output: { ami-build-<arch>, ami-test-<arch>, ami-status-<arch> }
  #         for each arch, plus a `ami-build-all` helper that runs
  #         every build sequentially.
  mkAmiBuildPipelines = {
    forgePackage,
    archs,                 # [ "aarch64" "x86_64" ]
    buildTemplateFor,      # arch -> derivation (Packer build template)
    testTemplateFor,       # arch -> derivation (Packer test template)
    ssmParameterFor,       # arch -> string (SSM path holding promoted AMI id)
    amiNameFor,            # arch -> string (Packer ami_name)
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    skipClusterTest ? false,
    clusterTestConfigFor ? null,  # arch -> derivation  (or null for skip)
    clusterTestInstanceType ? "c7i.xlarge",
    clusterTestTimeout ? 480,
    atticSsm ? null,
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
    makePublic ? false,
  }: let
    # Reuse the single-arch builder for each arch in the list, and
    # rewrite the resulting attribute keys to be arch-suffixed so
    # they can all coexist under `apps = { … }`.
    perArch = arch: let
      cluster = if clusterTestConfigFor == null then null else clusterTestConfigFor arch;
      apps = mkAmiBuildPipeline {
        inherit forgePackage region awsProfile extraBinaries
          skipClusterTest clusterTestInstanceType clusterTestTimeout
          atticSsm atticInstanceType atticCacheName makePublic;
        buildTemplate = buildTemplateFor arch;
        testTemplate  = testTemplateFor arch;
        ssmParameter  = ssmParameterFor arch;
        amiName       = amiNameFor arch;
        clusterTestConfig = cluster;
      };
    in
      pkgs.lib.mapAttrs' (name: value:
        pkgs.lib.nameValuePair "${name}-${arch}" value
      ) apps;

    merged = pkgs.lib.foldl' (a: b: a // b) {} (map perArch archs);

    # Convenience aggregator: run every ami-build-<arch> in order.
    buildAll = {
      type = "app";
      program = toString (pkgs.writeShellScript "ami-build-all" ''
        set -euo pipefail
        ${pkgs.lib.concatMapStringsSep "\n" (a: ''
          echo "=== build ${a} ==="
          ${merged."ami-build-${a}".program}
        '') archs}
      '');
    };
  in merged // { ami-build-all = buildAll; };
}
