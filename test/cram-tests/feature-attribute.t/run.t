A module declares the optional proposals it uses with a `#![feature = "…"]`
inner attribute (WAT: a `(@feature "…")` module annotation), so the file is
self-describing: it compiles and validates without every consumer passing
`-X`.

The attribute alone enables the feature — no `-X` needed:

  $ wax check desc.wax

  $ wax desc.wax -f wat
  (@feature "custom-descriptors")
  (rec
    (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    (type $obj_desc (describes $obj) (struct))
  )

Without the attribute (and without `-X`), the gated construct is rejected:

  $ wax check plain.wax
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  plain.wax:2:25
  1 │ rec {
  2 │   type obj = descriptor obj_desc { x: i32 };
    ·                         ^^^^^^^^
  3 │   type obj_desc = describes obj { };
  4 │ }
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  plain.wax:3:29
  1 │ rec {
  2 │   type obj = descriptor obj_desc { x: i32 };
  3 │   type obj_desc = describes obj { };
    ·                             ^^^
  4 │ }
  5 │ 
  [128]

The command line enabling the feature over a silent file still works:

  $ wax check -X custom-descriptors plain.wax

Both together are fine — the attribute states a fact, the flag a policy, and
they agree:

  $ wax check -X custom-descriptors desc.wax

An explicit `-X …=off` against a declaring module is a conflict, reported
once, at the attribute (not as a cascade of gated-construct errors):

  $ wax check -X custom-descriptors=off desc.wax
  Error:
    This module requires the custom-descriptors feature, which is disabled on
    the command line; drop --feature custom-descriptors=off.
   ──➤  desc.wax:1:14
  1 │ #![feature = "custom-descriptors"]
    ·              ^^^^^^^^^^^^^^^^^^^^
  2 │ rec {
  3 │   type obj = descriptor obj_desc { x: i32 };
  [128]

An unknown feature name is an error listing the known features:

  $ wax check unknown.wax
  Error:
    Unknown feature 'no-such-proposal'. Known features: custom-descriptors,
    compact-import-section.
   ──➤  unknown.wax:1:14
  1 │ #![feature = "no-such-proposal"]
    ·              ^^^^^^^^^^^^^^^^^^
  2 │ fn f() -> i32 { 0; }
  3 │ 
  [128]

A repeated attribute is accepted (declaring a feature is idempotent):

  $ wax check repeated.wax

The attribute round-trips: Wax → WAT keeps it as `(@feature …)` (above), and
WAT → Wax turns it back into the attribute:

  $ wax desc.wax -f wat -o desc.wat
  $ wax desc.wat -f wax
  #![feature = "custom-descriptors"]
  rec {
      type obj = descriptor obj_desc { x: i32 };
      type obj_desc = describes obj { };
  }

`format` never validates; the attribute is simply preserved:

  $ wax format desc.wax
  #![feature = "custom-descriptors"]
  rec {
      type obj = descriptor obj_desc { x: i32 };
      type obj_desc = describes obj { };
  }
  $ wax format desc.wat
  (@feature "custom-descriptors")
  (rec
    (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    (type $obj_desc (describes $obj) (struct))
  )

`--desugar` strips the annotation, honouring the flag's contract (plain
WebAssembly text, no annotations remain): it is pure metadata with no core
equivalent, and feature resolution has already run by the time desugaring
happens, so it still gates during processing. The gated *constructs* are real
proposal wasm and are not an error — annotation removal is orthogonal to
proposal support in the consumer:

  $ wax --desugar desc.wax -f wat
  (rec
    (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    (type $obj_desc (describes $obj) (struct))
  )

Like desugared strings, which do not come back as literals, the desugared text
no longer declares the feature, so re-ingesting it needs `-X` again:

  $ wax --desugar desc.wax -f wat -o desugared.wat
  $ wax check -X custom-descriptors desugared.wat
  $ wax check desugared.wat
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  desugared.wat:2:26
  1 │ (rec
  2 │   (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    ·                          ^^^^^^^^^
  3 │   (type $obj_desc (describes $obj) (struct))
  4 │ )
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  desugared.wat:3:30
  1 │ (rec
  2 │   (type $obj (descriptor $obj_desc) (struct (field $x i32)))
  3 │   (type $obj_desc (describes $obj) (struct))
    ·                              ^^^^
  4 │ )
  5 │ 
  [128]

The binary format persists the declarations through the conventional
`target_features` custom section (one `+name` entry per declared feature), so
a feature that is declared but not (yet) exercised by any construct still
survives a binary round-trip — usage detection alone could not see it:

  $ cat > unused.wax <<'EOF'
  > #![feature = "custom-descriptors"]
  > fn f() -> i32 { 0; }
  > EOF
  $ wax unused.wax -f wasm -o unused.wasm
  $ wax unused.wasm -f wax
  #![feature = "custom-descriptors"]
  type t = fn() -> i32;
  fn f() -> i32 {
      0;
  }

Emitting is idempotent: a second pass through the binary format changes
nothing (single section, no duplicate entries):

  $ wax -i wasm -f wasm unused.wasm -o unused2.wasm
  $ cmp unused.wasm unused2.wasm

Other producers' entries in an input section (unknown names, `-` entries) are
not ours to interpret: they do not become attributes, and they survive to
wasm output unchanged. Append a section with `+simd128` and
`-exception-handling` to a binary and round-trip it:

  $ python3 - <<'PY'
  > data = open("unused.wasm", "rb").read()
  > def leb(n):
  >     out = b""
  >     while True:
  >         b7 = n & 0x7f; n >>= 7
  >         out += bytes([b7 | (0x80 if n else 0)])
  >         if not n: return out
  > def name(s): return leb(len(s)) + s.encode()
  > entries = [(0x2B, "simd128"), (0x2D, "exception-handling")]
  > content = (name("target_features") + leb(len(entries))
  >            + b"".join(bytes([p]) + name(n) for p, n in entries))
  > open("foreign.wasm", "wb").write(data + bytes([0]) + leb(len(content)) + content)
  > PY
  $ wax -i wasm -f wasm foreign.wasm -o foreign2.wasm
  $ python3 - <<'PY'
  > data = open("foreign2.wasm", "rb").read()
  > i = data.index(b"target_features") + len(b"target_features")
  > n = data[i]; i += 1
  > for _ in range(n):
  >     prefix = chr(data[i]); ln = data[i+1]; i += 2
  >     print(prefix + data[i:i+ln].decode()); i += ln
  > PY
  +custom-descriptors
  +simd128
  -exception-handling

`compact-import-section` is an encoding choice gated on output: the attribute
enables it for the module's own emission, like `-X` does. The declaring module
compiles to a binary with the compact import section, which decompiles back
carrying the attribute (via the `target_features` entry, and independently via
the compact encoding the decoder sees):

  $ wax compact.wax -f wasm -o compact.wasm
  $ wax compact.wasm -f wat
  (@feature "compact-import-section")
  (type (func (param i32)))
  (type (func))
  (import "env" (item $a "a") (item $b "b") (func (param i32)))
  (func $main
    i32.const 1
    call $a
    i32.const 2
    call $b
  )
  (export "main" (func $main))

The conflict rule applies to it uniformly:

  $ wax compact.wax -f wasm -o /dev/null -X compact-import-section=off
  Error:
    This module requires the compact-import-section feature, which is disabled
    on the command line; drop --feature compact-import-section=off.
   ──➤  compact.wax:1:14
  1 │ #![feature = "compact-import-section"]
    ·              ^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ import "env" {
  3 │     fn a(i32);
  [128]
