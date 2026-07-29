A type the source uses only in a position the *lowering* has to spell out is
still used. Each of these three once escaped the Wax typer's reference tracking
and was wrongly reported by `unused-field`, while the validator — reading the
lowered wat, where the reference is explicit — kept it: a table's element type,
an imported function's signature type, and the array type behind a string
literal (a bare string names no type at all, so the typer records the use by
canonical index, as `string_type_reference` does on the validator side).

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the `unused`
group explicitly. Nothing is reported here:

  $ wax check -W unused=warning named.wax

  $ wax named.wax -f wat -o named.wat
  $ wax check -W unused=warning named.wat

An unbound name in that table element type is reported too. It used to reach the
lowering unchecked — `wax check` accepted the module and only the conversion to
another format rejected it:

  $ sed 's/&?elems/\&?nosuch/' named.wax > unbound.wax
  $ wax check unbound.wax
  Error: The type 'nosuch' is not bound.
    ──➤  unbound.wax:10:14
   8 │ 
   9 │ #[export]
  10 │ table tbl: &?nosuch [1];
     ·              ^^^^^^
  11 │ 
  12 │ #[export]
  [128]

The mirror case is a genuine one-sided asymmetry, and stays. Wax INFERS the type
of `g` here, naming `t` nowhere; the lowered wat must spell that type, because a
reference type can only name one. So the typer reports it and the validator does
not — and the typer is right: dropping the definition recompiles, with the
lowering interning an anonymous function type in its place.

  $ wax check -W unused=warning inferred.wax
  Warning [unused-field]: The type 't' is never used.
   ──➤  inferred.wax:1:6
  1 │ type t = fn();
    ·      ^
  2 │ 
  3 │ fn h() {}

  $ wax inferred.wax -f wat
  (type $t (func))
  
  (func $h)
  
  (global $g (export "g") (ref $t) (ref.func $h))

  $ wax inferred.wax -f wat -o inferred.wat
  $ wax check -W unused=warning inferred.wat
