#!/usr/bin/env python3
"""
render.py — proof-of-concept (defaction ...) → action triple renderer.

Generation over composition (Pillar 12), demonstrated. This Python
script is a STAND-IN for the eventual arch-synthesizer Rust binary
(ACTION-AS-CAIXA M1). The shape it produces should match what M1's
Rust renderer emits byte-for-byte.

Usage:
  python3 render.py cargo-bump.lisp ./out/

Emits to ./out/:
  cargo-bump/action.yml
  cargo-bump/run.tlisp
  cargo-bump/README.md
  patterns-entry.nix    (for splicing into substrate's patterns.nix)
"""
import re, sys
from pathlib import Path

# ── Naive S-expression reader — enough for the POC's `(defaction ...)` shape.
# Full M1 implementation uses tatara-lisp-source's real parser.

def read_form(src):
    """Read the (defaction name :slot value :slot value ...) form."""
    # Strip comments
    src = re.sub(r';;.*$', '', src, flags=re.M)
    # Match (defaction NAME ...rest)
    m = re.search(r'\(defaction\s+(\S+)\s*([\s\S]*)\)\s*$', src)
    if not m:
        raise SystemExit("no (defaction ...) form found")
    name = m.group(1)
    body_src = m.group(2)
    slots = parse_slots(body_src)
    return name, slots

def parse_slots(s):
    """Parse `:keyword value :keyword value ...` into a dict.
    Values can be strings, kebab-case identifiers, {dicts}, [vectors], or s-exprs."""
    slots = {}
    i = 0
    while i < len(s):
        # Skip whitespace
        while i < len(s) and s[i].isspace():
            i += 1
        if i >= len(s):
            break
        if s[i] != ':':
            # We're past the keyword section — rest is :body content
            break
        # Read keyword
        j = i + 1
        while j < len(s) and not s[j].isspace():
            j += 1
        kw = s[i+1:j]
        i = j
        # Skip whitespace
        while i < len(s) and s[i].isspace():
            i += 1
        # Read value
        val, end = read_value(s, i)
        slots[kw] = val
        i = end
        if kw == 'body':
            # Body is everything remaining
            break
    return slots

def read_value(s, i):
    """Read a single value starting at s[i]. Returns (value, end_index)."""
    if s[i] == '"':
        # String literal
        j = i + 1
        while j < len(s) and s[j] != '"':
            if s[j] == '\\':
                j += 2
            else:
                j += 1
        return s[i+1:j], j + 1
    if s[i] == '{':
        # Dict {:k v :k v}
        depth = 1
        j = i + 1
        while j < len(s) and depth > 0:
            if s[j] == '{': depth += 1
            elif s[j] == '}': depth -= 1
            elif s[j] == '"':
                j += 1
                while j < len(s) and s[j] != '"':
                    if s[j] == '\\': j += 2
                    else: j += 1
            j += 1
        inner = s[i+1:j-1]
        return parse_dict(inner), j
    if s[i] == '[':
        # Vector
        depth = 1
        j = i + 1
        while j < len(s) and depth > 0:
            if s[j] == '[': depth += 1
            elif s[j] == ']': depth -= 1
            j += 1
        inner = s[i+1:j-1]
        return parse_vector(inner), j
    if s[i] == '(':
        # S-expr (body)
        depth = 1
        j = i + 1
        while j < len(s) and depth > 0:
            if s[j] == '(': depth += 1
            elif s[j] == ')': depth -= 1
            elif s[j] == '"':
                j += 1
                while j < len(s) and s[j] != '"':
                    if s[j] == '\\': j += 2
                    else: j += 1
            j += 1
        return s[i:j], j
    # Bare token (kebab-case identifier or keyword)
    j = i
    while j < len(s) and not s[j].isspace():
        j += 1
    return s[i:j], j

def parse_dict(inner):
    """Recursively parse a {:k v :k v} dict."""
    d = {}
    i = 0
    while i < len(inner):
        while i < len(inner) and inner[i].isspace():
            i += 1
        if i >= len(inner) or inner[i] != ':':
            break
        j = i + 1
        while j < len(inner) and not inner[j].isspace():
            j += 1
        kw = inner[i+1:j]
        i = j
        while i < len(inner) and inner[i].isspace():
            i += 1
        val, end = read_value(inner, i)
        d[kw] = val
        i = end
    return d

def parse_vector(inner):
    """Parse a [a b c] vector."""
    out = []
    i = 0
    while i < len(inner):
        while i < len(inner) and inner[i].isspace():
            i += 1
        if i >= len(inner):
            break
        val, end = read_value(inner, i)
        out.append(val)
        i = end
    return out

# ── Emitters — produce each downstream artifact from the typed form

def emit_action_yml(name, slots):
    branding = slots.get('branding', {})
    icon = branding.get('icon', 'box')
    color = branding.get('color', 'gray-dark')
    inputs_src = slots.get('inputs', {})
    outputs_src = slots.get('outputs', {})

    yml = f"""name: 'pleme-io · {name}'
description: '{slots.get('description', '')}'
branding: {{ icon: '{icon}', color: '{color}' }}

inputs:
"""
    for iname, ispec in inputs_src.items():
        if isinstance(ispec, dict):
            required = 'required' in ispec and ispec['required'] == 'true'
            default = ispec.get('default')
            desc = ispec.get('description', '')
        else:
            required = True
            default = None
            desc = ''
        yml += f"  {iname}:\n"
        yml += f"    required: {'true' if required else 'false'}\n"
        if default is not None:
            yml += f"    default: \"{default}\"\n"
        if desc:
            yml += f"    description: \"{desc}\"\n"

    yml += "\noutputs:\n"
    for oname, ospec in outputs_src.items():
        yml += f"  {oname}:\n"
        yml += f"    value: ${{{{ steps.run.outputs.{oname} }}}}\n"
        if isinstance(ospec, dict) and 'description' in ospec:
            yml += f"    description: \"{ospec['description']}\"\n"

    installs = slots.get('installs', [])
    install_steps = ""
    for inst in installs:
        # ':rust-toolchain' → use dtolnay; ':nix' → install nix; etc.
        if inst == ':rust-toolchain':
            install_steps += "    - uses: dtolnay/rust-toolchain@stable\n"
        elif inst == ':cargo-edit':
            install_steps += "    - shell: bash\n      run: cargo install cargo-edit --locked\n"
        elif inst == ':nix':
            install_steps += "    - uses: DeterminateSystems/nix-installer-action@main\n"

    env_map = {}
    for iname in inputs_src:
        # Some kebab inputs need env-rename to avoid POSIX collisions
        rename = {'key': 'KEY_ARG', 'type': 'TYPE_ARG', 'url': 'URL_ARG',
                  'path': 'PATH_ARG', 'output': 'OUTPUT_ARG'}
        ev = rename.get(iname, iname.upper().replace('-', '_'))
        env_map[ev] = iname

    yml += "\nruns:\n  using: composite\n  steps:\n"
    yml += install_steps
    yml += """    - id: src
      shell: bash
      run: |
        {
          echo 'script<<TLISP_EOF'
          curl -sL https://raw.githubusercontent.com/pleme-io/actions/main/_tlisp-stdlib/stdlib.tlisp
          echo
          cat ${{ github.action_path }}/run.tlisp
          echo 'TLISP_EOF'
        } >> "$GITHUB_OUTPUT"
    - id: run
      uses: pleme-io/actions/tatara-script@v1
      with:
        script: ${{ steps.src.outputs.script }}
      env:
"""
    for ev, inv in env_map.items():
        yml += f"        {ev}: ${{{{ inputs.{inv} }}}}\n"
    return yml

def emit_run_tlisp(name, slots):
    body = slots.get('body', '').strip()
    return f""";; {name}/run.tlisp — RENDERED FROM (defaction {name} ...).
;; DO NOT EDIT — edit cargo-bump.lisp in the typescape instead.

{body}
"""

def emit_readme(name, slots):
    md = f"""# pleme-io · {name}

{slots.get('description', '')}

> AUTO-GENERATED from `cargo-bump.lisp` via the (defaction)
> renderer. Do not hand-edit; modify the typed Lisp source.

Part of the [pleme-io action catalog](https://github.com/pleme-io/actions).
Under the ★★ AUTO-RELEASE directive — see
[`pleme-io-auto-release`](https://github.com/pleme-io/blackmatter-pleme/blob/main/skills/pleme-io-auto-release/SKILL.md).

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
"""
    for iname, ispec in slots.get('inputs', {}).items():
        if isinstance(ispec, dict):
            req = 'no' if 'default' in ispec else 'yes'
            dflt = ispec.get('default', '—')
            desc = ispec.get('description', '')
        else:
            req, dflt, desc = 'yes', '—', ''
        md += f"| `{iname}` | {req} | `{dflt}` | {desc} |\n"

    md += "\n## Outputs\n\n| Name | Type | Description |\n|---|---|---|\n"
    for oname, ospec in slots.get('outputs', {}).items():
        if isinstance(ospec, dict):
            ty = ospec.get('type', ':string').lstrip(':')
            desc = ospec.get('description', '')
        else:
            ty, desc = 'string', ''
        md += f"| `{oname}` | `{ty}` | {desc} |\n"

    md += f"""
## Architecture

Rendered from `pleme-io/substrate/lib/release/renderer-poc/{name}.lisp`
by the (defaction) renderer. The hand-authored
`action.yml` + `run.tlisp` pair is GENERATED — see
[`substrate/docs/INTERLOCK.md`](https://github.com/pleme-io/substrate/blob/main/docs/INTERLOCK.md)
for the unified vision.
"""
    return md

def emit_patterns_entry(name, slots):
    cat = slots.get('category', ':uncategorized').lstrip(':')
    eco = slots.get('ecosystem', '')
    ecosystem_line = f'\n      ecosystem = "{eco.lstrip(":")}";' if eco else ''
    wraps = slots.get('wraps', '')
    tool_line = f'\n      tool = "{wraps}";' if wraps else ''
    return f"""  # auto-generated from {name}.lisp
  {cat} = {{
    {name} = {{
      uses = "pleme-io/actions/{name}@main";
      backend = "tatara-lisp";{ecosystem_line}{tool_line}
      role = "{slots.get('description', '')}";
    }};
  }};
"""

# ── Main

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <input.lisp> <output-dir>")
        sys.exit(1)
    src = Path(sys.argv[1]).read_text()
    out = Path(sys.argv[2])

    name, slots = read_form(src)
    triple_dir = out / name
    triple_dir.mkdir(parents=True, exist_ok=True)
    (triple_dir / 'action.yml').write_text(emit_action_yml(name, slots))
    (triple_dir / 'run.tlisp').write_text(emit_run_tlisp(name, slots))
    (triple_dir / 'README.md').write_text(emit_readme(name, slots))
    (out / 'patterns-entry.nix').write_text(emit_patterns_entry(name, slots))

    print(f"rendered:")
    for f in (triple_dir / 'action.yml', triple_dir / 'run.tlisp',
              triple_dir / 'README.md', out / 'patterns-entry.nix'):
        sz = f.stat().st_size
        print(f"  {f}  ({sz} bytes)")

    src_lines = len([l for l in src.splitlines() if l.strip() and not l.strip().startswith(';;')])
    gen_lines = sum(
        sum(1 for l in f.read_text().splitlines() if l.strip())
        for f in (triple_dir / 'action.yml', triple_dir / 'run.tlisp',
                  triple_dir / 'README.md', out / 'patterns-entry.nix')
    )
    print(f"\nsource non-comment lines: {src_lines}")
    print(f"generated non-empty lines: {gen_lines}")
    print(f"compounding ratio: {src_lines} → {gen_lines}  ({gen_lines/src_lines:.1f}×)")
