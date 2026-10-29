A type has at most 63 supertypes, transitively. A chain of 64 types is the
deepest allowed; past it, the first type over the limit is reported, once (a
deeper one is below it). Neither Wax nor WAT checked this.

  $ wax check ok.wax
  $ wax check ok.wat
  $ wax check deep.wax
  Error:
    This type has too many supertypes: a subtype hierarchy is at most 63 deep.
    ──➤  deep.wax:65:11
  63 │ type t62: t61 = open { };
  64 │ type t63: t62 = open { };
  65 │ type t64: t63 = open { };
     ·           ^^^
  66 │ type t65: t64 = open { };
  67 │ #[export]
  [128]
  $ wax check deep.wat
  Error:
    This type has too many supertypes: a subtype hierarchy is at most 63 deep.
    ──➤  deep.wat:66:3
  64 │   (type $t62 (sub $t61 (struct)))
  65 │   (type $t63 (sub $t62 (struct)))
  66 │   (type $t64 (sub $t63 (struct)))
     ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  67 │   (type $t65 (sub $t64 (struct)))
  68 │   (global (export "g") (ref null $t65) (ref.null $t65)))
  [128]
