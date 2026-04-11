# Unified Infrastructure Theory — Policy Layer
#
# Governance at declaration time. Policies are evaluated when archetypes
# are rendered — violations are errors, not warnings.
#
# Bridges the gap between Nix declarations and tameshi/kensa compliance.
# Policies are Nix functions that assert invariants on archetype specs.
#
# Pure functions — no pkgs dependency.
rec {
  # ── Create a named policy with rules ──────────────────────────
  mkPolicy = {
    name,
    description ? "",
    rules ? [],
  }: {
    inherit name description rules;
    # Evaluate this policy against a spec. Returns { valid, violations }.
    evaluate = spec: let
      results = map (rule: evaluateRule rule spec) rules;
      violations = builtins.filter (r: !r.valid) results;
    in {
      valid = violations == [];
      inherit violations;
      policy = name;
    };
  };

  # ── Evaluate a single rule against a spec ─────────────────────
  evaluateRule = rule: spec: let
    # Check if the rule's match criteria apply to this spec
    matches = matchSpec (rule.match or {}) spec;
  in if !matches then
    { valid = true; rule = rule.name or "unnamed"; message = "not applicable"; }
  else
    checkRequirements rule spec;

  # ── Match a spec against criteria ─────────────────────────────
  matchSpec = match: spec:
    (if match ? archetype then
      match.archetype == "*" || match.archetype == (spec.archetype or "")
    else true)
    && (if match ? env then
      match.env == (spec.meta.environment or spec.labels."app.pleme.io/environment" or "")
    else true)
    && (if match ? driver then
      match.driver == (spec.driver or "")
    else true);

  # ── Check requirements against a spec ─────────────────────────
  checkRequirements = rule: spec: let
    requireChecks = if rule ? require then
      builtins.attrValues (builtins.mapAttrs (field: expected:
        checkField field expected spec
      ) rule.require)
    else [];

    limitChecks = if rule ? limit then
      builtins.attrValues (builtins.mapAttrs (field: limit:
        checkLimit field limit spec
      ) rule.limit)
    else [];

    allChecks = requireChecks ++ limitChecks;
    failures = builtins.filter (c: !c.valid) allChecks;
  in if failures == [] then
    { valid = true; rule = rule.name or "unnamed"; message = "passed"; }
  else
    { valid = false; rule = rule.name or "unnamed";
      message = builtins.concatStringsSep "; " (map (f: f.message) failures); };

  # ── Check a required field ────────────────────────────────────
  checkField = field: expected: spec: let
    # Navigate dotted path: "scaling.min" → spec.scaling.min
    parts = builtins.filter (s: s != "") (builtins.split "\\." field);
    actual = builtins.foldl' (acc: part:
      if acc == null then null
      else if acc ? ${part} then acc.${part} else null
    ) spec parts;
  in if expected == "!null" then
    { valid = actual != null;
      message = if actual != null then "ok" else "${field} must not be null"; }
  else if builtins.isInt expected then
    let actualInt = if actual == null then 0 else if builtins.isInt actual then actual else 0;
    in { valid = actualInt >= expected;
         message = if actualInt >= expected then "ok"
                   else "${field} must be >= ${toString expected}, got ${toString actualInt}"; }
  else
    { valid = actual == expected;
      message = if actual == expected then "ok"
                else "${field} must be ${toString expected}"; };

  # ── Check a limit ─────────────────────────────────────────────
  checkLimit = field: limit: spec: let
    parts = builtins.filter (s: s != "") (builtins.split "\\." field);
    actual = builtins.foldl' (acc: part:
      if acc == null then null
      else if acc ? ${part} then acc.${part} else null
    ) spec parts;
    # Parse resource strings like "4000m" to integers
    parseResource = s:
      if builtins.isInt s then s
      else if builtins.isString s then
        let m = builtins.match "([0-9]+)m?" s;
        in if m != null then builtins.fromJSON (builtins.head m) else 0
      else 0;
    actualVal = parseResource (if actual == null then "0" else actual);
    limitVal = parseResource limit;
  in {
    valid = actualVal <= limitVal;
    message = if actualVal <= limitVal then "ok"
              else "${field} exceeds limit: ${toString actualVal} > ${toString limitVal}";
  };

  # ── Evaluate multiple policies against a spec ─────────────────
  evaluateAll = policies: spec:
    let results = map (p: p.evaluate spec) policies;
        allViolations = builtins.concatMap (r: r.violations) results;
    in {
      valid = allViolations == [];
      violations = allViolations;
    };

  # ── Assert policies (throw on violation) ──────────────────────
  assertPolicies = policies: spec:
    let result = evaluateAll policies spec;
    in if result.valid then spec
       else throw "Policy violations:\n${builtins.concatStringsSep "\n" (map (v:
         "  [${v.rule}] ${v.message}"
       ) result.violations)}";
}
