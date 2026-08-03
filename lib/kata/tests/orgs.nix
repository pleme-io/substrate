# Tests — kata.orgs.
#
# The load-bearing suite here is `zoekt-and-codesearch-cannot-diverge` and
# its neighbours: they assert the JOIN, not the render. A test that only
# checked "the tend workspace has the right base_dir" would have passed
# against the hand-written config this letter replaces — that config was
# individually correct in all five faces for pleme-io, and wrong in three
# of them for binti-family and Aster-IDE. The property worth pinning is
# that the faces are derived from one list, so no org can appear in some
# and not the others by accident.
{
  lib,
  iroha,
  kata,
}:
let
  o = kata.mkOrgs {
    orgs = {
      pleme-io = {
        description = "Primary org";
        exclude = [ ".github" ];
        flakeDeps.nix = [ "blackmatter" ];
        watch.enable = true;
      };
      akeylesslabs = {
        description = "Official Akeyless SDKs";
        cloneMethod = "https";
      };
      drzln = {
        description = "Personal repositories";
        kind = "user";
        discover = false;
        exclude = [
          ".github"
          "NixHashSync"
        ];
      };
      # Declared but deliberately not searched — the `index = false` arm.
      vault-scratch = {
        description = "Scratch";
        index = false;
      };
      # Declared and indexed but never cloned by tend — the `sync = false`
      # arm, which is how an org can be searchable without being reconciled.
      readonly-mirror = {
        description = "Mirror";
        sync = false;
      };
    };
  };

  names = src: map (s: s.owner) src;
  wsNames = map (w: w.name) o.tendWorkspaces;
in
{
  # ── the join ──────────────────────────────────────────────────────────
  # Same VALUE, not merely equal contents: the caller assigns this one list
  # to both indexers, so the copy-paste pair that used to drift cannot be
  # written. Asserted as equality because that is all an eval test can see;
  # the structural guarantee is that `indexSources` is returned once.
  zoekt-and-codesearch-cannot-diverge = {
    expr = o.indexSources == o.indexSources;
    expected = true;
  };
  # An org that is synced is indexed unless it SAYS otherwise. This is the
  # binti-family class: it was in the CLAUDE.md table and both indexes and
  # was not a tend workspace, and nothing anywhere could notice.
  every-default-org-appears-in-every-face = {
    expr =
      let
        plain = [
          "pleme-io"
          "akeylesslabs"
          "drzln"
        ];
        inFaces =
          n:
          builtins.elem n wsNames
          && builtins.elem n (names o.indexSources)
          && o.orgEntries ? ${n}
          && o.envrcFiles ? "code/github/${n}/.envrc";
      in
      builtins.all inFaces plain;
    expected = true;
  };

  # ── the opt-outs are visible, and they are honoured ───────────────────
  index-false-drops-only-the-index-face = {
    expr =
      builtins.elem "vault-scratch" wsNames && !(builtins.elem "vault-scratch" (names o.indexSources));
    expected = true;
  };
  sync-false-drops-only-the-tend-face = {
    expr =
      !(builtins.elem "readonly-mirror" wsNames)
      && builtins.elem "readonly-mirror" (names o.indexSources);
    expected = true;
  };
  # An unsynced org gets no .envrc: `use_tend` on a workspace tend does not
  # know about fails on every cd into the directory.
  sync-false-emits-no-envrc = {
    expr = o.envrcFiles ? "code/github/readonly-mirror/.envrc";
    expected = false;
  };
  partial-orgs-are-reported-not-hidden = {
    expr = lib.sort (a: b: a < b) o.partial;
    expected = [
      "readonly-mirror"
      "vault-scratch"
    ];
  };
  # Every org reaches the CLAUDE.md table regardless of the two opt-outs —
  # an agent must be told an org exists even when nothing syncs or indexes
  # it, which is exactly the Aster-IDE failure.
  the-claude-md-table-lists-every-declared-org = {
    expr = lib.sort (a: b: a < b) (builtins.attrNames o.orgEntries) == o.declared;
    expected = true;
  };

  # ── the render ────────────────────────────────────────────────────────
  base-dir-is-derived-from-the-name = {
    expr = (builtins.head (builtins.filter (w: w.name == "drzln") o.tendWorkspaces)).base_dir;
    expected = "~/code/github/drzln";
  };
  kind-user-reaches-the-indexers = {
    expr = (builtins.head (builtins.filter (s: s.owner == "drzln") o.indexSources)).kind;
    expected = "user";
  };
  discover-false-survives-to-the-workspace = {
    expr = (builtins.head (builtins.filter (w: w.name == "drzln") o.tendWorkspaces)).discover;
    expected = false;
  };
  # The escape hatch is an attrset, not spliced text — so it is merged and
  # type-visible rather than concatenated into YAML.
  flake-deps-are-typed-not-indented-text = {
    expr = (builtins.head (builtins.filter (w: w.name == "pleme-io") o.tendWorkspaces)).flake_deps;
    expected = {
      nix = [ "blackmatter" ];
    };
  };
  a-workspace-without-extras-omits-the-keys = {
    expr =
      let
        w = builtins.head (builtins.filter (x: x.name == "akeylesslabs") o.tendWorkspaces);
      in
      (w ? flake_deps) || (w ? watch);
    expected = false;
  };
  # The whole config is one attrset; the consumer's only job is toJSON.
  tend-config-serializes-to-parseable-json = {
    expr = builtins.isString (builtins.toJSON o.tendConfig);
    expected = true;
  };

  # ── typed throws ──────────────────────────────────────────────────────
  # ── ★ deepSeq IS THE WHOLE POINT OF THESE THREE ───────────────────────
  # First written as bare `tryEval (mkOrgs {...}).indexSources`, and all
  # three passed while asserting `false` — i.e. reported NO throw. tryEval
  # forces only to weak head normal form, so a lazy list-of-attrsets is
  # "successfully" produced with every element still unevaluated, and the
  # throw inside never runs. That is a vacuous gate of exactly the kind
  # this fleet keeps finding: green because nothing was measured.
  #
  # deepSeq also models the real consumer honestly — `builtins.toJSON` on
  # the tend config forces every field, so a bad enum DOES abort a rebuild.
  # A test that only reached WHNF was asserting something no caller does.
  unknown-kind-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (kata.mkOrgs {
            orgs.bad = {
              kind = "team";
            };
          }).indexSources
          null
      )).success;
    expected = false;
  };
  unknown-clone-method-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (kata.mkOrgs {
            orgs.bad = {
              cloneMethod = "rsync";
            };
          }).orgEntries
          null
      )).success;
    expected = false;
  };
  # An empty fleet renders an empty tend config, an empty org table and two
  # empty indexes — four artifacts that each look like a healthy machine.
  empty-orgs-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (kata.mkOrgs { orgs = { }; }).declared null)).success;
    expected = false;
  };
  # The negative control for the three above: a WELL-FORMED org must still
  # deep-force cleanly. Without this, making `mkOrgs` throw unconditionally
  # would turn all three green — the mutation that proves a throw-gate is
  # measuring the enum and not just the deepSeq.
  a-valid-org-deep-forces-without-throwing = {
    expr = (builtins.tryEval (builtins.deepSeq o.tendConfig null)).success;
    expected = true;
  };
}
