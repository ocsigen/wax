Decompiling WAT to Wax walks a function body several times — to find the used
locals, to reserve module-entity names, to collect element-segment references.
Each walk must descend into instruction-level `(@if …)` bodies, or an entity
referenced ONLY inside a conditional is missed and conversion spuriously fails
on a module `wax check` accepts.

A parameter used only inside `(@if)` is not "unused" — it keeps its name:

  $ cat > param.wat <<'WAT'
  > (module (func (param i32) (result i32)
  >   (@if $D (@then (local.get 0)) (@else (i32.const 1)))))
  > WAT

  $ wax -i wat -f wax param.wat
  fn f(x: i32) -> i32 {
      #[if(D)]
      {
          x;
      }
      #[else]
      {
          1;
      }
  }

And each configuration still round-trips to valid WebAssembly:

  $ wax -i wat -f wax param.wat | wax -i wax -f wasm -D D=true -o /dev/null --validate && echo OK
  OK
  $ wax -i wat -f wax param.wat | wax -i wax -f wasm -D D=false -o /dev/null --validate && echo OK
  OK

A memory accessed only via an atomic inside `(@if)` is name-reserved, so the
unnamed parameter renames around it rather than the memory receiver resolving to
the parameter:

  $ cat > atomic.wat <<'WAT'
  > (module (memory $x 1 1 shared)
  >   (func (param i32) (result i32)
  >     (@if $D (@then (i32.atomic.load (local.get 0))) (@else (local.get 0)))))
  > WAT

  $ wax -i wat -f wax atomic.wat
  memory x: i32 [1, 1] shared;
  fn f(x_2: i32) -> i32 {
      #[if(D)]
      {
          x.atomic_load32(x_2);
      }
      #[else]
      {
          x_2;
      }
  }

A declarative element segment `elem.drop`ped only inside `(@if)` keeps its
declaration and its name stays bound:

  $ cat > elem.wat <<'WAT'
  > (module (func $h) (elem declare func $h)
  >   (func $g (@if $D (@then (elem.drop 0)))))
  > WAT

  $ wax -i wat -f wax elem.wat
  fn h() {}
  elem e: &func = [];
  fn g() {
      #[if(D)]
      {
          e.drop();
      }
  }
