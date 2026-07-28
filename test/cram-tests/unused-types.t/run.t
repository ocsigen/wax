A type definition nothing reachable names is reported by `unused-field`, like any
other module field. Types are reached through the same reachability analysis (see
`unused-fields-reachability.t`): a type named by a live function's signature,
locals or body is live, and so is one named by a live *type* — its supertype, a
field or element type, a `descriptor` clause. That last edge is what makes a
mutually recursive group work: a `rec` group nothing outside it names is dead as a
whole, its members' references to each other notwithstanding.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the `unused`
group explicitly.

  $ wax check -W unused=warning types.wat
  Warning [unused-field]: The function '$dead' is never used.
    ──➤  types.wat:18:9
  16 │     (type $rec_live_b (struct (field (ref null $rec_live_a)))))
  17 │   (type $only_in_dead_body (struct (field i32)))
  18 │   (func $dead (result (ref null $only_in_dead_body))
     ·         ^^^^^
  19 │     (ref.null $only_in_dead_body))
  20 │   (func (export "f")
  Warning [unused-field]: The type '$unused' is never used.
   ──➤  types.wat:3:3
  1 │ (module
  2 │   (type $used (struct (field $a i32)))
  3 │   (type $unused (struct (field i32)))
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │   (type $_ignored (struct))
  5 │   (type $reached_via_field (struct (field i32)))
  Warning [unused-field]: The type '$dead_target' is never used.
   ──➤  types.wat:7:3
  5 │   (type $reached_via_field (struct (field i32)))
  6 │   (type $holder (struct (field (ref null $reached_via_field))))
  7 │   (type $dead_target (struct (field i64)))
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │   (type $dead_holder (struct (field (ref null $dead_target))))
  9 │   ;; dead cycle: the two only name each other
  Warning [unused-field]: The type '$dead_holder' is never used.
    ──➤  types.wat:8:3
   6 │   (type $holder (struct (field (ref null $reached_via_field))))
   7 │   (type $dead_target (struct (field i64)))
   8 │   (type $dead_holder (struct (field (ref null $dead_target))))
     ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   9 │   ;; dead cycle: the two only name each other
  10 │   (rec
  Warning [unused-field]: The type '$rec_dead_a' is never used.
    ──➤  types.wat:11:5
   9 │   ;; dead cycle: the two only name each other
  10 │   (rec
  11 │     (type $rec_dead_a (struct (field (ref null $rec_dead_b))))
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  12 │     (type $rec_dead_b (struct (field (ref null $rec_dead_a)))))
  13 │   ;; live cycle: reached through the exported function's signature
  Warning [unused-field]: The type '$rec_dead_b' is never used.
    ──➤  types.wat:12:5
  10 │   (rec
  11 │     (type $rec_dead_a (struct (field (ref null $rec_dead_b))))
  12 │     (type $rec_dead_b (struct (field (ref null $rec_dead_a)))))
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  13 │   ;; live cycle: reached through the exported function's signature
  14 │   (rec
  Warning [unused-field]: The type '$only_in_dead_body' is never used.
    ──➤  types.wat:17:3
  15 │     (type $rec_live_a (struct (field (ref null $rec_live_b))))
  16 │     (type $rec_live_b (struct (field (ref null $rec_live_a)))))
  17 │   (type $only_in_dead_body (struct (field i32)))
     ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  18 │   (func $dead (result (ref null $only_in_dead_body))
  19 │     (ref.null $only_in_dead_body))

`$unused` is named nowhere. `$dead_holder` is dead, and so is `$dead_target`,
which only it names. `$rec_dead_a`/`$rec_dead_b` are the dead cycle. And
`$only_in_dead_body` is named only by `$dead` — a function that cannot run — so it
goes too, while `$holder`, `$reached_via_field` (reached through `$holder`'s field)
and the live `rec` pair stay. `$_ignored` is exempt by its leading `_`, and the
implicit function types interned for an inline signature are never candidates:
only a definition written in the source is.

The Wax type checker reports the same seven fields (the order differs: it walks
the module once, reporting each field where it is declared):

  $ wax check -W unused=warning types.wax
  Warning [unused-field]: The type 'unused' is never used.
   ──➤  types.wax:2:6
  1 │ type used = { a: i32 };
  2 │ type unused = { b: i32 };
    ·      ^^^^^^
  3 │ type _ignored = { c: i32 };
  4 │ type reached_via_field = { n: i32 };
  Warning [unused-field]: The type 'dead_target' is never used.
   ──➤  types.wax:6:6
  4 │ type reached_via_field = { n: i32 };
  5 │ type holder = { r: &?reached_via_field };
  6 │ type dead_target = { d: i64 };
    ·      ^^^^^^^^^^^
  7 │ type dead_holder = { r: &?dead_target };
  8 │ // dead cycle: the two only name each other
  Warning [unused-field]: The type 'dead_holder' is never used.
   ──➤  types.wax:7:6
  5 │ type holder = { r: &?reached_via_field };
  6 │ type dead_target = { d: i64 };
  7 │ type dead_holder = { r: &?dead_target };
    ·      ^^^^^^^^^^^
  8 │ // dead cycle: the two only name each other
  9 │ rec {
  Warning [unused-field]: The type 'rec_dead_a' is never used.
    ──➤  types.wax:10:10
   8 │ // dead cycle: the two only name each other
   9 │ rec {
  10 │     type rec_dead_a = { x: &?rec_dead_b };
     ·          ^^^^^^^^^^
  11 │     type rec_dead_b = { y: &?rec_dead_a };
  12 │ }
  Warning [unused-field]: The type 'rec_dead_b' is never used.
    ──➤  types.wax:11:10
   9 │ rec {
  10 │     type rec_dead_a = { x: &?rec_dead_b };
  11 │     type rec_dead_b = { y: &?rec_dead_a };
     ·          ^^^^^^^^^^
  12 │ }
  13 │ // live cycle: reached through the exported function's signature
  Warning [unused-field]: The type 'only_in_dead_body' is never used.
    ──➤  types.wax:18:6
  16 │     type rec_live_b = { y: &?rec_live_a };
  17 │ }
  18 │ type only_in_dead_body = { z: i32 };
     ·      ^^^^^^^^^^^^^^^^^
  19 │ 
  20 │ fn dead() -> &?only_in_dead_body { null }
  Warning [unused-field]: The function 'dead' is never used.
    ──➤  types.wax:20:4
  18 │ type only_in_dead_body = { z: i32 };
  19 │ 
  20 │ fn dead() -> &?only_in_dead_body { null }
     ·    ^^^^
  21 │ 
  22 │ #[export = "f"]
