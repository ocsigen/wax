A custom descriptor (the custom-descriptors proposal) attaches a descriptor
struct to another struct. Wax spells the two clauses as [descriptor <name>] (on
the described type) and [describes <name>] (on the descriptor), between the
[open] marker and the struct body. They must pair up within a single [rec] group.

  $ wax --validate desc.wax -f wat
  (rec
    (type $obj (descriptor $obj_desc) (struct (field $x i32)))
    (type $obj_desc (describes $obj) (struct))
  )

The clauses survive a binary round-trip.

  $ wax desc.wax -f wasm -o desc.wasm
  $ wax desc.wasm -f wax
  rec { type obj = descriptor obj_desc { x: i32 }; type obj_desc = describes obj { }; }

A descriptor and its described type must refer to each other.

  $ wax check not-reciprocal.wax
  Error: The descriptor of this type does not describe it back.
   ──➤  not-reciprocal.wax:2:3
  1 │ rec {
  2 │   type a = descriptor b { };
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │   type b = { };
  4 │ }
  [123]


Both types in a descriptor pair must be structs.

  $ wax check not-struct.wax
  Error: A descriptor type must be a struct type.
   ──➤  not-struct.wax:2:3
  1 │ rec {
  2 │   type a = descriptor b fn();
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │   type b = describes a { };
  4 │ }
  [123]


If a supertype has a descriptor, its subtype must have one too.

  $ wax check sub-missing-descriptor.wax
  Error: This type is not a valid subtype of 'a'.
   ──➤  sub-missing-descriptor.wax:4:11
  2 │   type a = open descriptor a_desc { };
  3 │   type a_desc = open describes a { };
  4 │   type b: a = open { };
    ·           ^
  5 │ }
  6 │ 
  [123]

