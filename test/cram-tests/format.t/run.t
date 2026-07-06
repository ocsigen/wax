The 'format' subcommand reformats files in their own format. Without
--inplace it takes exactly one file and writes to stdout:

  $ wax format a.wat
  (func $f (result i32) (i32.const 1))

More than one file without --inplace is an error:

  $ wax format a.wat b.wax
  Exactly one input file must be specified without --inplace or --check.
  [123]

A file whose format cannot be detected is reported:

  $ wax format no-extension
  no-extension: cannot detect format (expected .wat, .wax or .wasm)
  [123]

With --inplace (-i) it rewrites each file, accepting several at once (copied to
writable names first, as the test inputs are read-only):

  $ cat a.wat > x.wat; cat b.wax > y.wax
  $ wax format -i x.wat y.wax
  $ cat x.wat
  (func $f (result i32) (i32.const 1))
  $ cat y.wax
  fn g(x: i32) -> i32 {
      x;
  }

Formatting is idempotent:

  $ wax format -i x.wat y.wax
  $ cat x.wat
  (func $f (result i32) (i32.const 1))
  $ cat y.wax
  fn g(x: i32) -> i32 {
      x;
  }

--check writes nothing and lists files that are not already formatted, taking
several files and exiting non-zero when any differ:

  $ wax format --check a.wat b.wax
  a.wat
  b.wax
  [123]

An already-formatted file passes silently:

  $ wax format --check x.wat y.wax

--check and --inplace cannot be combined:

  $ wax format --check -i x.wat
  --inplace and --check cannot be combined.
  [123]

--format (-f) overrides the extension-based format detection:

  $ cat a.wat > m.txt
  $ wax format -f wat m.txt
  (func $f (result i32) (i32.const 1))

Long tag headers keep `tag` on the opening line when formatting wraps:

  $ cat > tag.wat <<'EOF'
  > (tag $very_long_tag_name (param (ref $some_really_long_type_name)) (param (ref $some_really_long_type_name_2)) (result (ref $some_really_long_type_name_3)))
  > EOF
  $ wax format -f wat tag.wat
  (tag $very_long_tag_name
    (param
      (ref $some_really_long_type_name)
      (ref $some_really_long_type_name_2))
    (result (ref $some_really_long_type_name_3))
  )

Long Wax data initializers indent the string continuation, both at top level and
inside a memory block.

  $ cat > data.wax <<'EOF'
  > data d_9 @ zstd_memory [3396] =
  > "\01\00\00\00\02\00\00\00\04\00\00\00\00\00\00\00\02\00\00\00\04\00\00\00\08\00\00\00\00\00\00\00\01\00\00\00\02\00\00\00\01\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\08\00\00\00\08\00\00\00\08\00\00\00\07\00\00\00\08\00\00\00\09\00\00\00\0a\00\00\00\0b";
  > memory zstd_memory: i32 {
  >     data d_9 @ [3396] = "\01\00\00\00\02\00\00\00\04\00\00\00\00\00\00\00\02\00\00\00\04\00\00\00\08\00\00\00\00\00\00\00\01\00\00\00\02\00\00\00\01\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\08\00\00\00\08\00\00\00\08\00\00\00\07\00\00\00\08\00\00\00\09\00\00\00\0a\00\00\00\0b";
  > }
  > EOF
  $ wax format -f wax data.wax
  data d_9 @ zstd_memory [3396] =
      "\01\00\00\00\02\00\00\00\04\00\00\00\00\00\00\00\02\00\00\00\04\00\00\00\08\00\00\00\00\00\00\00\01\00\00\00\02\00\00\00\01\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\08\00\00\00\08\00\00\00\08\00\00\00\07\00\00\00\08\00\00\00\t\00\00\00\n\00\00\00\0b";
  memory zstd_memory: i32 {
      data d_9 @ [3396] =
          "\01\00\00\00\02\00\00\00\04\00\00\00\00\00\00\00\02\00\00\00\04\00\00\00\08\00\00\00\00\00\00\00\01\00\00\00\02\00\00\00\01\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\04\00\00\00\08\00\00\00\08\00\00\00\08\00\00\00\07\00\00\00\08\00\00\00\t\00\00\00\n\00\00\00\0b";
  }

Long table, elem, and active-data declarations indent continuations, and
bracketed offsets / element lists expand into structured multi-line blocks.

  $ cat > wrap.wax <<'EOF'
  > table tab0: i64 &?func [10, 20] = some_really_long_initializer_expression.with_a_really_long_method_name(argument_one, argument_two, argument_three);
  > elem seg: &?func = [handler_with_a_really_long_name_a, handler_with_a_really_long_name_b, handler_with_a_really_long_name_c, handler_with_a_really_long_name_d, handler_with_a_really_long_name_e];
  > elem seg2: &?func @ funcs[some_really_long_offset_expression.with_a_really_long_method_name(argument_one, argument_two, argument_three)] = [handler_with_a_really_long_name_a, handler_with_a_really_long_name_b, handler_with_a_really_long_name_c, handler_with_a_really_long_name_d];
  > data d @ mem0[some_really_long_offset_expression.with_a_really_long_method_name(argument_one, argument_two, argument_three)] = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
  > EOF
  $ wax format -f wax wrap.wax
  table tab0: i64 &?func [10, 20] =
      some_really_long_initializer_expression.with_a_really_long_method_name(
          argument_one,
          argument_two,
          argument_three,
      );
  elem seg: &?func = [
          handler_with_a_really_long_name_a, handler_with_a_really_long_name_b,
          handler_with_a_really_long_name_c, handler_with_a_really_long_name_d,
          handler_with_a_really_long_name_e
      ];
  elem seg2: &?func @ funcs [
          some_really_long_offset_expression.with_a_really_long_method_name(
              argument_one,
              argument_two,
              argument_three,
          )
      ] = [
          handler_with_a_really_long_name_a, handler_with_a_really_long_name_b,
          handler_with_a_really_long_name_c, handler_with_a_really_long_name_d
      ];
  data d @ mem0 [
          some_really_long_offset_expression.with_a_really_long_method_name(
              argument_one,
              argument_two,
              argument_three,
          )
      ] =
      "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";

Long aggregate segment constructors use the same structured bracket layout.

  $ cat > agg.wax <<'EOF'
  > type bytes = [mut i8];
  > const a = [bytes| seg @ offset_expr.with_a_really_long_method_name(argument_one, argument_two, argument_three); count_expr.with_a_really_long_method_name(argument_one, argument_two, argument_three)];
  > EOF
  $ wax format -f wax agg.wax
  type bytes = [mut i8];
  const a =
      [bytes| seg @
          offset_expr.with_a_really_long_method_name(argument_one, argument_two, argument_three);
          count_expr.with_a_really_long_method_name(argument_one, argument_two, argument_three)
      ];
