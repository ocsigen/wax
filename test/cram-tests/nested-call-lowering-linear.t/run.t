A memory access rebuilds its own operand code during lowering, so the shared
argument lowering must be lazy — otherwise each argument is lowered twice, and a
nested call re-enters the same arm, compounding to exponential work in the
nesting depth (a few dozen levels already takes seconds; a hundred is
intractable). This pins the lowering as linear: a deeply nested chain converts
essentially instantly.

  $ python3 -c 'e="0"
  > for _ in range(100): e="mem.load32(%s)" % e
  > open("deep.wax","w").write("memory mem: i32 [1];\nfn f() -> i32 { %s; }\n" % e)'

  $ python3 -c 'import subprocess
  > subprocess.run(["wax","deep.wax","-f","wat","-o","/dev/null"],timeout=60,check=True)
  > print("OK")'
  OK

It also still lowers to correct, valid wasm:

  $ python3 -c 'e="0"
  > for _ in range(6): e="mem.load32(%s)" % e
  > open("small.wax","w").write("memory mem: i32 [1];\nfn f() -> i32 { %s; }\n" % e)'

  $ wax small.wax -f wat
  (memory $mem 1)
  (func $f (result i32)
    (i32.load $mem
      (i32.load $mem
        (i32.load $mem
          (i32.load $mem (i32.load $mem (i32.load $mem (i32.const 0)))))))
  )
