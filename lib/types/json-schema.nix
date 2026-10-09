# JSON Schema → module-system option types
#
# One Rust type is the source of truth for a config: a shikumi-typed struct
# derives `schemars::JsonSchema`, `schema_for!` emits its JSON Schema, and this
# file turns that schema into `lib.types.*` values and `mkOption`s. A NixOS /
# nix-darwin / home-manager module then exposes the SAME shape the binary
# deserializes — typed, documented, defaulted — without anyone restating it.
#
# Pure — depends only on nixpkgs lib. Input shape: what schemars 1.x emits for
# serde types (draft 2020-12). The fixtures under lib/tests/fixtures/json-schema
# are real schemars 1.2.2 output, not hand-written approximations.
#
#   js = import "${substrate}/lib/types/json-schema.nix" { inherit lib; };
#   # or: (import "${substrate}/lib/types" { inherit lib; }).jsonSchema
#
#   options.services.foo.settings = js.optionsFromJsonSchema { inherit lib; schema = ./foo.schema.json; };
#   options.services.foo.auth     = lib.mkOption { type = js.fromJsonSchema { inherit lib; schema = ./auth.schema.json; }; };
#   # render: pkgs.formats.yaml {} … (js.pruneNulls cfg.settings)
#
# ── THE MAPPING ────────────────────────────────────────────────────────────
#
#   type object + properties          → submodule (CLOSED: unknown keys are an
#                                        eval error even without
#                                        `deny_unknown_fields` — a typo'd key
#                                        serde would ignore is a bug here)
#     required prop                   → mkOption { type = T; }
#     optional prop with `default`    → mkOption { type = T; default = …; }
#     optional prop without default   → mkOption { type = nullOr T; default = null; }
#   … + additionalProperties schema   → submodule with freeformType attrsOf S
#   type object, only additionalProps → attrsOf S          (HashMap / BTreeMap)
#   type string | boolean             → str | bool         (`format` on strings is
#                                                          an annotation, per spec)
#   type integer + format             → ints.{s8,s16,s32,u8,u16,u32,unsigned} / int
#   type number                       → number             (int or float)
#   minimum/maximum/exclusive*/multipleOf, minItems/maxItems/uniqueItems → addCheck
#   type array + items                → listOf S
#   type [X, "null"] / nullable: true → nullOr X
#   enum / const                      → enum
#   oneOf of objects each with ONE required key and additionalProperties:false
#     (serde's externally-tagged enum) → attrTag            (+ `either enum` when
#                                                          unit variants are mixed in)
#   oneOf / anyOf of consts           → enum               (documented unit variants)
#   any other oneOf / anyOf           → types.oneOf, each alternative guarded by a
#                                       SHALLOW discriminator (key set, required
#                                       keys, const-valued props) — a bare
#                                       submodule's check is `isAttrs`, which would
#                                       let the first object alternative swallow
#                                       every attrset (internally-tagged and
#                                       untagged enums both rely on this)
#   $ref "#", "#/$defs/X", "#/definitions/X", any local pointer
#                                     → a lazy proxy type named after the target:
#                                       recursion (`Chain(Vec<Self>)`) is safe, and
#                                       a description reads "list of GithubAuth"
#                                       instead of recursing forever.
#   true / {}                         → anything (the schema says "any value";
#                                       serde_json::Value emits exactly this)
#
# ── REFUSAL, NEVER A SILENT WIDENING ───────────────────────────────────────
#
# Every keyword is either mapped above, a pure annotation (title, description,
# default, examples, $comment, x-*, …), or a THROW naming its JSON pointer.
# The check is an EAGER structural audit of the whole document — every
# property, every $defs entry, whether or not an option ever forces it — run
# before the root type is returned. A lazy converter alone would leave an
# unsupported keyword on an unset option undetected until someone set it.
# Unsupported today (each throws): pattern, minLength, maxLength (Nix measures
# bytes, JSON Schema code points — a wrong length check is worse than none),
# prefixItems (tuples), patternProperties, propertyNames, min/maxProperties,
# not, if/then/else, dependent*, unevaluated*, contains, allOf with >1 member,
# non-local $ref, and $ref cycles that pass through no object/array/map (they
# admit no finite discriminator).
{ lib }:

let
  impl =
    lib:
    let
      inherit (lib) types mkOption;
      inherit (builtins)
        isAttrs
        isList
        isString
        isInt
        isFloat
        isBool
        attrNames
        elem
        all
        any
        length
        head
        filter
        concatMap
        concatStringsSep
        genList
        elemAt
        ;

      # ── Errors ─────────────────────────────────────────────────────────
      escapeSeg = s: builtins.replaceStrings [ "~" "/" ] [ "~0" "~1" ] (toString s);
      pointer = path: "#" + concatStringsSep "" (map (s: "/" + escapeSeg s) path);
      fail = path: msg: throw "substrate jsonSchema: ${msg} at ${pointer path}";

      # ── Keyword vocabulary ─────────────────────────────────────────────
      annotationKeys = [
        "$schema"
        "$id"
        "$anchor"
        "$comment"
        "title"
        "description"
        "default"
        "examples"
        "example"
        "deprecated"
        "readOnly"
        "writeOnly"
        "$defs"
        "definitions"
      ];
      isAnnotation = k: elem k annotationKeys || lib.hasPrefix "x-" k;
      structural = s: filter (k: !isAnnotation k) (attrNames s);

      numericKeys = [
        "format"
        "minimum"
        "maximum"
        "exclusiveMinimum"
        "exclusiveMaximum"
        "multipleOf"
      ];
      kindKeys = {
        integer = numericKeys;
        number = numericKeys;
        string = [ "format" ];
        boolean = [ ];
        null = [ ];
        array = [
          "items"
          "minItems"
          "maxItems"
          "uniqueItems"
        ];
        object = [
          "properties"
          "required"
          "additionalProperties"
        ];
      };
      knownKinds = attrNames kindKeys;
      intFormats = [
        "int8"
        "int16"
        "int32"
        "int64"
        "int"
        "uint8"
        "uint16"
        "uint32"
        "uint64"
        "uint"
      ];

      whyUnsupported = {
        pattern = "ECMA-262 regexes do not translate faithfully to Nix's POSIX ERE";
        minLength = "Nix measures bytes, JSON Schema measures code points";
        maxLength = "Nix measures bytes, JSON Schema measures code points";
        prefixItems = "tuples are not mapped yet";
        patternProperties = "regex-keyed maps are not mapped yet";
        propertyNames = "key schemas are not mapped yet";
        not = "negation has no module-system type";
        "if" = "conditional schemas are not mapped";
        allOf = "allOf with more than one member is not mapped";
      };
      unsupported =
        path: k:
        fail (path ++ [ k ]) (
          "unsupported keyword `${k}`" + lib.optionalString (whyUnsupported ? ${k}) " (${whyUnsupported.${k}})"
        );

      typeList = s: if !(s ? type) then [ ] else if isList s.type then s.type else [ s.type ];

      # The one "shape driver" of a schema node. Exactly one may be present;
      # a node carrying two (`$ref` + `properties`, `oneOf` + `type`) would
      # have the converter honour one and silently drop the other.
      driverOf =
        path: s:
        let
          has = k: s ? ${k};
          drivers = filter has [
            "$ref"
            "oneOf"
            "anyOf"
            "allOf"
          ];
        in
        if length drivers > 1 then
          fail path "more than one of ${concatStringsSep ", " drivers} on one schema"
        else if drivers != [ ] then
          head drivers
        else if has "const" || has "enum" then
          "literal"
        else
          "typed";

      # Kinds a typed node stands for: its `type`, or inferred from its keys.
      kindsOf =
        s:
        let
          declared = typeList s;
        in
        if declared != [ ] then
          declared
        else if s ? properties || s ? additionalProperties || s ? required then
          [ "object" ]
        else if s ? items then
          [ "array" ]
        else
          [ ];

      # ── Pointers ───────────────────────────────────────────────────────
      unescapeSeg = s: builtins.replaceStrings [ "~1" "~0" ] [ "/" "~" ] s;
      refPath =
        path: ref:
        if !isString ref then
          fail path "`$ref` must be a string"
        else if ref == "#" then
          [ ]
        else if lib.hasPrefix "#/" ref then
          map unescapeSeg (lib.splitString "/" (lib.removePrefix "#/" ref))
        else
          fail path "non-local `$ref` \"${ref}\" (only \"#...\" pointers into this document are supported)";

      walk =
        root: path: ref:
        lib.foldl' (
          node: seg:
          if isAttrs node && node ? ${seg} then
            node.${seg}
          else if isList node && builtins.match "[0-9]+" seg != null && lib.toInt seg < length node then
            elemAt node (lib.toInt seg)
          else
            fail path "`$ref` \"${ref}\" does not resolve (no `${seg}`)"
        ) root (refPath path ref);

      # ── Literal / tag shape detection (schema-level, no types) ─────────
      onlyKeys = s: ks: all (k: elem k ks) (structural s);
      isNullSchema = s: isAttrs s && typeList s == [ "null" ] && onlyKeys s [ "type" ];
      isLiteral =
        s:
        isAttrs s
        && (s ? const || s ? enum)
        && onlyKeys s [
          "type"
          "format"
          "const"
          "enum"
          "nullable"
        ];
      literalValues = s: if s ? const then [ s.const ] else s.enum;
      # serde's externally-tagged variant: `{ "<variant>": <payload> }`, closed.
      tagOf =
        s:
        if
          isAttrs s
          && typeList s == [ "object" ]
          && onlyKeys s [
            "type"
            "properties"
            "required"
            "additionalProperties"
          ]
          && isAttrs (s.properties or null)
          && length (attrNames s.properties) == 1
          && (s.required or [ ]) == attrNames s.properties
          && (s.additionalProperties or null) == false
        then
          head (attrNames s.properties)
        else
          null;

      mkCtx =
        {
          root,
          attrTagImpl,
          unfold ? true,
        }:
        let
          # The same conversion with recursive refs NOT unfolded in docs.
          # Only `getSubOptions` ever reaches it, so it is never built for
          # value checking.
          flatCtx = mkCtx {
            inherit root attrTagImpl;
            unfold = false;
          };
          resolve = path: ref: walk root path ref;

          # ── Audit: eager, structural, finite (refs are not followed) ───
          audit =
            path: s:
            if isBool s then
              (if s then true else fail path "the `false` schema admits no value")
            else if !isAttrs s then
              fail path "a schema must be an object or a boolean"
            else
              let
                driver = driverOf path s;
                kinds = kindsOf s;
                sub = k: v: audit (path ++ [ k ]) v;
                subList =
                  k:
                  if !isList s.${k} || s.${k} == [ ] then
                    fail (path ++ [ k ]) "`${k}` must be a non-empty list"
                  else
                    all (x: x) (genList (i: audit (path ++ [ k (toString i) ]) (elemAt s.${k} i)) (length s.${k}));
                defsOk =
                  all (
                    dk:
                    if s ? ${dk} then
                      all (n: audit (path ++ [ dk n ]) s.${dk}.${n}) (attrNames s.${dk})
                    else
                      true
                  ) [ "$defs" "definitions" ];
                allowed =
                  if driver == "typed" then
                    [
                      "type"
                      "nullable"
                    ]
                    ++ concatMap (
                      k: if elem k knownKinds then kindKeys.${k} else fail (path ++ [ "type" ]) "unknown type `${toString k}`"
                    ) kinds
                  else if driver == "literal" then
                    [
                      "type"
                      "format"
                      "const"
                      "enum"
                      "nullable"
                    ]
                  else
                    [
                      driver
                      "nullable"
                    ];
                keysOk = all (k: elem k allowed || unsupported path k) (structural s);
                bodyOk =
                  if driver == "$ref" then
                    builtins.seq (resolve path s."$ref") true
                  else if driver == "oneOf" || driver == "anyOf" then
                    subList driver
                  else if driver == "allOf" then
                    (if isList s.allOf && length s.allOf == 1 then subList "allOf" else unsupported path "allOf")
                  else if driver == "literal" then
                    (
                      if s ? const && s ? enum then
                        fail path "both `const` and `enum`"
                      else if s ? enum && (!isList s.enum || s.enum == [ ]) then
                        fail (path ++ [ "enum" ]) "`enum` must be a non-empty list"
                      else
                        true
                    )
                  else
                    let
                      props = s.properties or { };
                      req = s.required or [ ];
                    in
                    (
                      if !isAttrs props then
                        fail (path ++ [ "properties" ]) "`properties` must be an object"
                      else
                        all (n: audit (path ++ [ "properties" n ]) props.${n}) (attrNames props)
                    )
                    && (
                      if !isList req then
                        fail (path ++ [ "required" ]) "`required` must be a list"
                      else
                        all (r: props ? ${r} || fail (path ++ [ "required" ]) "required key `${toString r}` has no property schema") req
                    )
                    && (if s ? additionalProperties then auditAP (path ++ [ "additionalProperties" ]) s.additionalProperties else true)
                    && (if s ? items then sub "items" s.items else true)
                    && (
                      if s ? format && elem "integer" kinds && !(elem s.format intFormats) then
                        fail (path ++ [ "format" ]) "unknown integer format `${s.format}`"
                      else if s ? format && elem "number" kinds && !elem "integer" kinds && !(elem s.format [ "float" "double" ]) then
                        fail (path ++ [ "format" ]) "unknown number format `${s.format}`"
                      else
                        true
                    )
                    && (if s ? multipleOf && !isInt s.multipleOf then fail (path ++ [ "multipleOf" ]) "non-integer `multipleOf`" else true);
              in
              keysOk && bodyOk && defsOk;

          # `additionalProperties: false` is a boolean schema that is legal in
          # that position (it means "closed"), so it bypasses the `false`
          # refusal above.
          auditAP = path: v: if v == false then true else audit path v;

          # ── Every $ref string in the document, and the ref graph ───────
          refsIn =
            s:
            if isAttrs s then
              (if s ? "$ref" && isString s."$ref" then [ s."$ref" ] else [ ])
              ++ concatMap (k: if k == "$ref" then [ ] else refsIn s.${k}) (attrNames s)
            else if isList s then
              concatMap refsIn s
            else
              [ ];
          allRefs = lib.unique (refsIn root);

          # Refs reachable WITHOUT passing a value-consuming constructor
          # (object/array/map). A cycle here is a type no finite value can
          # discriminate — refused.
          shallowRefs =
            s:
            if !isAttrs s then
              [ ]
            else if s ? "$ref" then
              [ s."$ref" ]
            else
              concatMap (k: if s ? ${k} then concatMap shallowRefs s.${k} else [ ]) [
                "oneOf"
                "anyOf"
                "allOf"
              ];
          reach =
            edges: start:
            let
              go =
                seen: todo:
                if todo == [ ] then
                  seen
                else
                  let
                    r = head todo;
                    rest = builtins.tail todo;
                  in
                  if elem r seen then go seen rest else go (seen ++ [ r ]) (rest ++ edges r);
            in
            go [ ] (edges start);
          shallowEdges = r: shallowRefs (resolve [ ] r);
          deepEdges = r: refsIn (resolve [ ] r);
          shallowCycles = filter (r: elem r (reach shallowEdges r)) allRefs;
          # Refs to targets that can reach themselves through anything —
          # docs (getSubOptions) stop there instead of unfolding forever.
          recursiveRefs = filter (r: elem r (reach deepEdges r)) allRefs;

          audited =
            audit [ ] root
            && (
              if shallowCycles != [ ] then
                fail [ ] "`$ref` cycle with no object/array/map in between (${concatStringsSep ", " shallowCycles})"
              else
                true
            );

          # ── Conversion ─────────────────────────────────────────────────
          memo = lib.genAttrs allRefs (r: convert (refPath [ ] r) (resolve [ ] r));

          refName =
            r:
            if r == "#" then
              root.title or "root"
            else
              let
                p = refPath [ ] r;
              in
              if p == [ ] then "root" else lib.last p;

          # A proxy type: delegates check/merge to the memoized target, but
          # its OWN description is the target's name, so a recursive type
          # never forces an infinite description string.
          refType =
            r:
            let
              t = memo.${r};
              recursive = elem r recursiveRefs;
            in
            lib.mkOptionType {
              name = "jsonSchemaRef";
              description = refName r;
              descriptionClass = "noun";
              check = {
                __functor = _: v: t.check v;
                isV2MergeCoherent = true;
              };
              merge = {
                __functor =
                  self: loc: defs:
                  (self.v2 { inherit loc defs; }).value;
                v2 =
                  { loc, defs }@args:
                  if t.merge ? v2 then
                    t.merge.v2 args
                  else
                    {
                      value = t.merge loc defs;
                      headError =
                        if all (d: t.check d.value) defs then
                          null
                        else
                          { message = "Definition values: ${lib.options.showDefs (filter (d: !t.check d.value) defs)}"; };
                      valueMeta = { };
                    };
              };
              emptyValue = t.emptyValue or { };
              # Docs: a recursive ref unfolds ONE level (through flatCtx, whose
              # recursive refs stop), so `chain`'s members are documented once
              # instead of forever.
              getSubOptions =
                prefix:
                if !recursive then
                  t.getSubOptions prefix
                else if unfold then
                  flatCtx.memo.${r}.getSubOptions prefix
                else
                  { };
            };

          nullType = lib.mkOptionType {
            name = "null";
            description = "null";
            descriptionClass = "noun";
            check = v: v == null;
            merge = lib.options.mergeEqualOption;
          };

          # Integer formats schemars emits, and the bounds each already implies.
          intBounds = {
            int8 = [ (-128) 127 types.ints.s8 ];
            int16 = [ (-32768) 32767 types.ints.s16 ];
            int32 = [ (-2147483648) 2147483647 types.ints.s32 ];
            int64 = [ null null types.int ];
            int = [ null null types.int ];
            uint8 = [ 0 255 types.ints.u8 ];
            uint16 = [ 0 65535 types.ints.u16 ];
            uint32 = [ 0 4294967295 types.ints.u32 ];
            # Nix ints are signed 64-bit: values above 2^63-1 cannot be written.
            uint64 = [ 0 null types.ints.unsigned ];
            uint = [ 0 null types.ints.unsigned ];
          };

          withChecks =
            t: preds:
            if preds == [ ] then
              t
            else
              (types.addCheck t (v: all (p: p.ok v) preds))
              // {
                description = "${t.description} (${concatStringsSep ", " (map (p: p.text) preds)})";
              };

          numericPreds =
            s: lo: hi:
            lib.optional (s ? minimum && (lo == null || s.minimum > lo)) {
              ok = v: v >= s.minimum;
              text = ">= ${toString s.minimum}";
            }
            ++ lib.optional (s ? maximum && (hi == null || s.maximum < hi)) {
              ok = v: v <= s.maximum;
              text = "<= ${toString s.maximum}";
            }
            ++ lib.optional (s ? exclusiveMinimum) {
              ok = v: v > s.exclusiveMinimum;
              text = "> ${toString s.exclusiveMinimum}";
            }
            ++ lib.optional (s ? exclusiveMaximum) {
              ok = v: v < s.exclusiveMaximum;
              text = "< ${toString s.exclusiveMaximum}";
            }
            ++ lib.optional (s ? multipleOf) {
              ok = v: isInt v && lib.mod v s.multipleOf == 0;
              text = "multiple of ${toString s.multipleOf}";
            };

          convertKind =
            path: s: kind:
            if kind == "string" then
              types.str
            else if kind == "boolean" then
              types.bool
            else if kind == "null" then
              nullType
            else if kind == "integer" then
              let
                b = intBounds.${s.format or "int64"};
              in
              withChecks (elemAt b 2) (numericPreds s (elemAt b 0) (elemAt b 1))
            else if kind == "number" then
              withChecks types.number (numericPreds s null null)
            else if kind == "array" then
              withChecks (types.listOf (if s ? items then convert (path ++ [ "items" ]) s.items else types.anything)) (
                lib.optional (s ? minItems) {
                  ok = v: length v >= s.minItems;
                  text = "at least ${toString s.minItems} items";
                }
                ++ lib.optional (s ? maxItems) {
                  ok = v: length v <= s.maxItems;
                  text = "at most ${toString s.maxItems} items";
                }
                ++ lib.optional (s.uniqueItems or false) {
                  ok = v: length (lib.unique v) == length v;
                  text = "unique items";
                }
              )
            else
              # object
              let
                props = s.properties or { };
                ap = s.additionalProperties or null;
                apType = if ap == true then types.anything else convert (path ++ [ "additionalProperties" ]) ap;
                open = ap != null && ap != false;
              in
              if props == { } && open then
                types.attrsOf apType
              else
                types.submodule {
                  options = propOptions path s;
                  freeformType = if open then types.attrsOf apType else null;
                };

          isNullable = s: s.nullable or false || elem "null" (typeList s);

          convertTyped =
            path: s:
            let
              kinds = filter (k: k != "null") (kindsOf s);
              base =
                if kindsOf s == [ ] then
                  types.anything
                else if kinds == [ ] then
                  nullType
                else
                  types.oneOf (map (convertKind path s) kinds);
            in
            if isNullable s && kinds != [ ] then types.nullOr base else base;

          mkTagged =
            path: alts:
            let
              tagged = filter (a: tagOf a.s != null) alts;
              tags = lib.listToAttrs (
                map (
                  a:
                  let
                    k = tagOf a.s;
                  in
                  lib.nameValuePair k (
                    mkOption (
                      {
                        type = convert (a.path ++ [ "properties" k ]) a.s.properties.${k};
                      }
                      // lib.optionalAttrs (a.s ? description) { inherit (a.s) description; }
                    )
                  )
                ) tagged
              );
            in
            if attrTagImpl == "native" then types.attrTag tags else fallbackAttrTag tags;

          # Exactly-one-key tagged union for nixpkgs without `types.attrTag`
          # (< 24.05). Same contract: one key, from the declared set, its
          # value merged through that tag's option.
          fallbackAttrTag =
            tags:
            lib.mkOptionType {
              name = "attrTag";
              description = "attribute-tagged union with choices: ${concatStringsSep ", " (attrNames tags)}";
              descriptionClass = "noun";
              check = v: isAttrs v && length (attrNames v) == 1 && tags ? ${head (attrNames v)};
              merge =
                loc: defs:
                let
                  choice = head (attrNames (head defs).value);
                  vals = map (
                    d:
                    if attrNames d.value != [ choice ] then
                      throw "The option `${lib.showOption loc}` is defined both as `${choice}` and `${head (attrNames d.value)}`."
                    else
                      {
                        inherit (d) file;
                        value = d.value.${choice};
                      }
                  ) defs;
                in
                {
                  ${choice} = (lib.modules.evalOptionValue (loc ++ [ choice ]) tags.${choice} vals).value;
                };
              getSubOptions = prefix: lib.mapAttrs (n: o: o // { loc = prefix ++ [ n ]; }) tags;
              nestedTypes = tags;
            }
            // {
              jsonSchemaFallback = true;
            };

          # Shallow discriminator for a union alternative: looks only at the
          # value's top level (kind, key set, required keys, const-valued
          # props). The alternative's own type still does the deep check.
          admits =
            s: v:
            if isBool s then
              s
            else if s ? "$ref" then
              admits (resolve [ ] s."$ref") v
            else if s ? oneOf || s ? anyOf then
              (isNullable s && v == null) || any (a: admits a v) (s.oneOf or s.anyOf)
            else if s ? allOf then
              admits (head s.allOf) v
            else if s ? const || s ? enum then
              elem v (literalValues s) || (isNullable s && v == null)
            else
              let
                ks = kindsOf s;
              in
              ks == [ ]
              || (isNullable s && v == null)
              || any (
                k:
                if k == "object" then
                  isAttrs v
                  && (
                    let
                      props = s.properties or { };
                      closed = (s.additionalProperties or null) == null || s.additionalProperties == false;
                    in
                    (!closed || all (n: props ? ${n}) (attrNames v))
                    && all (r: v ? ${r}) (s.required or [ ])
                    && all (n: !(v ? ${n}) || !isLiteral props.${n} || elem v.${n} (literalValues props.${n})) (
                      attrNames props
                    )
                  )
                else if k == "array" then
                  isList v
                else if k == "string" then
                  isString v
                else if k == "integer" then
                  isInt v
                else if k == "number" then
                  isInt v || isFloat v
                else if k == "boolean" then
                  isBool v
                else
                  v == null
              ) ks;

          convertUnion =
            path: s: kw:
            let
              indexed = genList (i: {
                s = elemAt s.${kw} i;
                path = path ++ [
                  kw
                  (toString i)
                ];
              }) (length s.${kw});
              nulls = filter (a: isNullSchema a.s) indexed;
              rest = filter (a: !isNullSchema a.s) indexed;
              lits = filter (a: isLiteral a.s) rest;
              others = filter (a: !isLiteral a.s) rest;
              litValues = lib.unique (concatMap (a: literalValues a.s) lits);
              tagKeys = map (a: tagOf a.s) others;
              allTagged =
                kw == "oneOf" && others != [ ] && all (k: k != null) tagKeys && length (lib.unique tagKeys) == length tagKeys;
              litType = types.enum litValues;
              core =
                if rest == [ ] then
                  nullType
                else if others == [ ] then
                  litType
                else if allTagged then
                  (if lits == [ ] then mkTagged path others else types.either litType (mkTagged path others))
                else
                  let
                    guarded = map (a: types.addCheck (convert a.path a.s) (admits a.s)) others;
                    all' = (lib.optional (lits != [ ]) litType) ++ guarded;
                  in
                  if length all' == 1 then head all' else types.oneOf all';
            in
            if (nulls != [ ] || s.nullable or false) && rest != [ ] then types.nullOr core else core;

          convert =
            path: s:
            if isBool s then
              types.anything # `true`; `false` was refused by the audit
            else
              let
                driver = driverOf path s;
                t =
                  if driver == "$ref" then
                    refType s."$ref"
                  else if driver == "oneOf" || driver == "anyOf" then
                    convertUnion path s driver
                  else if driver == "allOf" then
                    convert (path ++ [ "allOf" "0" ]) (head s.allOf)
                  else if driver == "literal" then
                    types.enum (literalValues s)
                  else
                    convertTyped path s;
              in
              if driver != "typed" && driver != "oneOf" && driver != "anyOf" && isNullable s then
                types.nullOr t
              else
                t;

          # ── Options for an object schema's properties ──────────────────
          describe =
            s:
            if isAttrs s && s ? description then
              s.description
            else if isAttrs s && s ? "$ref" then
              (resolve [ ] s."$ref").description or null
            else
              null;

          nullableSchema =
            s:
            isAttrs s
            && (
              isNullable s
              || any isNullSchema (s.oneOf or s.anyOf or [ ])
              || (s ? "$ref" && nullableSchema (resolve [ ] s."$ref"))
            );

          propOption =
            path: required: name: ps:
            let
              p = path ++ [
                "properties"
                name
              ];
              t = convert p ps;
              hasDefault = isAttrs ps && ps ? default;
              desc = describe ps;
              example =
                if isAttrs ps && ps ? examples && isList ps.examples && ps.examples != [ ] then
                  { example = head ps.examples; }
                else if isAttrs ps && ps ? example then
                  { inherit (ps) example; }
                else
                  { };
              optional = !required;
              needsNull = optional && (!hasDefault || ps.default == null) && !nullableSchema ps;
            in
            mkOption (
              {
                type = if needsNull then types.nullOr t else t;
              }
              // lib.optionalAttrs hasDefault { inherit (ps) default; }
              // lib.optionalAttrs (optional && !hasDefault) { default = null; }
              // lib.optionalAttrs (desc != null) { description = desc; }
              // example
            );

          propOptions =
            path: s:
            let
              req = s.required or [ ];
            in
            lib.mapAttrs (n: ps: propOption path (elem n req) n ps) (s.properties or { });

          objectRoot =
            let
              go =
                seen: path: s:
                if isAttrs s && s ? "$ref" && !(elem s."$ref" seen) then
                  go (seen ++ [ s."$ref" ]) (refPath path s."$ref") (resolve path s."$ref")
                else if isAttrs s && s ? allOf && length s.allOf == 1 then
                  go seen (path ++ [ "allOf" "0" ]) (head s.allOf)
                else
                  { inherit path s; };
            in
            go [ ] [ ] root;
        in
        {
          inherit audited memo;
          rootType = convert [ ] root;
          rootOptions =
            let
              inherit (objectRoot) path s;
              ap = s.additionalProperties or null;
            in
            if !(isAttrs s && elem "object" (kindsOf s) && s ? properties) then
              fail path "optionsFromJsonSchema needs an object schema with `properties` (use fromJsonSchema for any other root)"
            else if ap != null && ap != false then
              fail (path ++ [ "additionalProperties" ]) "an open object cannot be flattened into an options set (use fromJsonSchema, which keeps its freeformType)"
            else
              propOptions path s;
        };

      load =
        schema:
        if builtins.isPath schema || (isString schema && lib.hasPrefix "/" schema) then
          lib.importJSON schema
        else if isAttrs schema || isBool schema then
          schema
        else
          throw "substrate jsonSchema: `schema` must be a parsed attrset or a path to a .json file";

      ctxFor =
        {
          schema,
          attrTagImpl ? "auto",
        }:
        mkCtx {
          root = load schema;
          attrTagImpl =
            if attrTagImpl == "auto" then
              (if types ? attrTag then "native" else "fallback")
            else if elem attrTagImpl [ "native" "fallback" ] then
              attrTagImpl
            else
              throw "substrate jsonSchema: attrTagImpl must be auto, native or fallback";
        };
    in
    {
      fromJsonSchema =
        args:
        let
          c = ctxFor args;
        in
        builtins.seq c.audited c.rootType;

      optionsFromJsonSchema =
        args:
        let
          c = ctxFor args;
        in
        builtins.seq c.audited c.rootOptions;
    };

  # A value merged from these options carries `null` for every optional field
  # left unset. serde reads a MISSING field as its default; it reads `null`
  # only for `Option<T>`. Prune before rendering to YAML/JSON/TOML. Nulls
  # inside lists are kept (`Vec<Option<T>>` means them).
  pruneNulls =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: pruneNulls) (lib.filterAttrs (_: x: x != null) v)
    else if builtins.isList v then
      map pruneNulls v
    else
      v;

  pick = args: impl (args.lib or lib);
in
{
  # fromJsonSchema { lib, schema, attrTagImpl ? "auto" } → the root's type.
  fromJsonSchema = args: (pick args).fromJsonSchema (removeAttrs args [ "lib" ]);
  # optionsFromJsonSchema { lib, schema, … } → { <prop> = mkOption …; } for an
  # object root (descriptions, defaults, examples carried over).
  optionsFromJsonSchema = args: (pick args).optionsFromJsonSchema (removeAttrs args [ "lib" ]);
  inherit pruneNulls;
}
