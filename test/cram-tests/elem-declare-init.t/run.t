A declarative element segment is normally dropped on conversion to Wax (it is
regenerated from `ref.func` usage). But when it is referenced by `table.init`
(or `elem.drop` / `array.*_elem`) it needs an explicit binding, so it is emitted
as an empty passive segment — runtime-equivalent, since a declarative segment is
a dropped passive one (`table.init` of a non-zero length traps either way).

  $ wax decl-init.wat -f wax -o out.wax && cat out.wax
  table t: &?func [10];
  elem e: &func = [];
  fn f() {}
  #[export = "init"]
  fn init() { t.init(e, 0, 0, 1); }

The result is valid (the reference resolves and the module type-checks):

  $ wax out.wax -i wax -f wasm -o out.wasm --validate
