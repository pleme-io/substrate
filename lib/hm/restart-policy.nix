# Restart policy — one closed vocabulary for "when does the service manager
# start this daemon again", projected onto each service manager's own knob.
#
# launchd and systemd both answer the question, in different spellings:
#
#   policy        launchd KeepAlive                              systemd Restart=
#   ──────────    ───────────────────────────────────────────    ────────────────
#   always        true                                           always
#   on-failure    { SuccessfulExit = false; Crashed = true; }    on-failure
#
# `on-failure` is the policy for a daemon that can END ON PURPOSE: exit 0
# means "stay down", anything else (a non-zero status, a crash) means "bring
# me back". Under `always`, a deliberate exit is indistinguishable from a
# crash and the daemon is relaunched whatever it said.
#
# The launchd arm is the shape two hand-written agents in the fleet had
# already arrived at independently (bm-complete, skim-tab-daemon); `Crashed`
# is kept beside `SuccessfulExit` because launchd documents the two keys
# separately and a signal death is the one case a reader must not have to
# reason about.
#
# The projections are total over the enum: a policy with no spelling on some
# service manager cannot be added without adding it here.
{ lib }:
rec {
  policies = [ "always" "on-failure" ];

  type = lib.types.enum policies;

  launchdKeepAlive = policy: {
    always = true;
    on-failure = { SuccessfulExit = false; Crashed = true; };
  }.${policy};

  systemdRestart = policy: {
    always = "always";
    on-failure = "on-failure";
  }.${policy};

  # The helpers' form: a helper takes `restartPolicy ? null` beside its raw
  # knob, and null leaves the raw knob in charge. The argument is always
  # passed, so a module computing the policy from `config` never makes the
  # helper's argument SET depend on `config` — that would be an infinite
  # recursion, because the module system needs the helper's output keys
  # before `config` exists.
  keepAliveOr = keepAlive: policy:
    if policy == null then keepAlive else launchdKeepAlive policy;
  restartOr = restart: policy:
    if policy == null then restart else systemdRestart policy;
}
