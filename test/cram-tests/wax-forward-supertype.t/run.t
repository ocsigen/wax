A supertype must be declared before its subtype. A forward reference within a
rec group, or a self-reference, is reported as unbound (rather than crashing
the type-checker):

  $ wax check forward.wax
  Error: The type 'b' is not bound.
   ──➤  forward.wax:2:11
  1 │ rec {
  2 │   type a: b = open { };
    ·           ^
  3 │   type b = open { };
  4 │ }
  [128]

  $ wax check self.wax
  Error: The type 'a' is not bound.
   ──➤  self.wax:1:9
  1 │ type a: a = open { };
    ·         ^
  2 │ 
  [128]

A supertype declared earlier in the rec group is fine:

  $ wax check ok.wax
