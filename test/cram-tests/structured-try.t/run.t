The structured try: braced catch arms with inline bodies, in the
dispatch/match family, lowering to the standard try_table plus a block ladder.
The body's completion escapes past all arms (one implicit branch supplying the
try's value); arms are honest trailing code in clause order — an arm's
completion falls into the next arm (its entry stack: the tag's payload, plus
the &exn above it for a `&` arm), the last arm's completion supplies the
try's value. An early arm escapes with its value via a label on the try (the
join). The catch-all is grammar-enforced last; omitting it lets unmatched
exceptions propagate.

  $ wax --validate try.wax -f wat
  (tag $overflow (param i32))
  (tag $timeout)
  (tag $jsexc (param (ref eq)))
  (tag $ocamlexc (param (ref eq)))
  
  (func $find (param $k i32) (result i32)
    (if (i32.gt_s (local.get $k) (i32.const 10))
      (then (throw $overflow (local.get $k))))
    (local.get $k)
  )
  (func $wrap (param $e (ref eq)) (result (ref eq)) (local.get $e))
  
  ;; multi-arm fall-through with payload handoff, catch-all default
  (func $f (param $k i32) (result i32)
    (block $t (result i32)
      (block $catch_2
        (block $catch_1 (result (ref exn))
          (block $catch (result i32)
            (br $t
              (try_table (result i32)
                (catch $overflow $catch) (catch_ref $timeout $catch_1)
                (catch_all $catch_2)
                (call $find (local.get $k)))))
          (br $t))
        (drop)
        (br $t (i32.sub (i32.const 0) (i32.const 1))))
      (i32.const 0))
  )
  
  ;; normalize-then-handle: first arm's completion IS the second arm's payload
  (func $norm (param $p i32) (result (ref eq))
    (local $res (ref eq))
    (local.set $res
      (block $join (result (ref eq))
        (block $catch_1 (result (ref eq))
          (block $catch (result (ref eq))
            (br $join
              (try_table (result (ref eq))
                (catch $jsexc $catch) (catch $ocamlexc $catch_1)
                (throw $jsexc (ref.i31 (local.get $p))))))
          (call $wrap))))
    (local.get $res)
  )
  
  ;; propagation with no catch-all; void try
  (func $v (param $k i32)
    (block $join
      (block $catch
        (try_table (catch $timeout $catch) (drop (call $find (local.get $k))))
        (br $join)))
  )
  
  ;; expression-position try with a diverging arm
  (func $e (param $k i32) (result i32)
    (i32.add
      (block $join (result i32)
        (block $catch (result i32)
          (br $join
            (try_table (result i32)
              (catch $overflow $catch)
              (call $find (local.get $k)))))
        (drop)
        (return (i32.sub (i32.const 0) (i32.const 1)))) (i32.const 1))
  )

Round trip: the compiled ladders recover to the same structured forms — the
branch-escape, fall-through payload-handoff (normalize-then-handle), void,
and trailing-diverging shapes alike — and re-compilation is a fixed point.

  $ wax try.wax -o try.wasm
  $ wax try.wasm -f wax -o dec.wax
  $ cat dec.wax
  type t = fn(i32) -> i32;
  type t_2 = fn(&eq) -> &eq;
  type t_3 = fn(i32) -> &eq;
  type t_4 = fn(i32);
  type t_5 = fn();
  type t_6 = fn(&eq);
  fn find(k: i32) -> i32 {
      if k >s 10 {
          throw overflow(k);
      }
      k;
  }
  fn wrap(e: &eq) -> &eq {
      e;
  }
  fn f(k: i32) -> i32 {
      't: try {
          find(k);
      } catch {
          overflow => {
              br 't _;
          }
          timeout & => {
              _ = _;
              br 't 0 - 1;
          }
          _ => {
              0;
          }
      }
  }
  fn norm(p: i32) -> &eq {
      let res =
          try {
              throw jsexc(p as &i31);
          } catch {
              jsexc => {
                  wrap(_);
              }
              ocamlexc => {}
          };
      res;
  }
  fn v(k: i32) {
      try {
          _ = find(k);
      } catch { timeout => {} }
  }
  fn e(k: i32) -> i32 {
      (try {
           find(k);
       } catch {
           overflow => {
               _ = _;
               return 0 - 1;
           }
       } + 1);
  }
  tag overflow: t_4 ;
  tag timeout: t_5 ;
  tag jsexc: t_6 ;
  tag ocamlexc: t_6 ;
  $ wax dec.wax -o try2.wasm
  $ wax try2.wasm -f wax -o dec2.wax
  $ cmp dec.wax dec2.wax

A `&` arm delivers the &exn above the payload; a catch-all `&` arm can
rethrow it:

  $ wax --validate rethrow.wax -f wat
  (tag $overflow (param i32))
  (func $f (param $k i32) (result i32)
    (block $t (result i32)
      (block $catch_1 (result (ref exn))
        (block $catch (result i32)
          (br $t
            (try_table (result i32)
              (catch $overflow $catch) (catch_all_ref $catch_1)
              (local.get $k))))
        (drop)
        (br $t (i32.const 0)))
      (throw_ref))
  )

Arm k's completion must match arm k+1's entry stack: a passed-through payload
does not fit a parameterless catch-all.

  $ wax check errors.wax
  Error: This value remains on the stack.
    ──➤  errors.wax:10:23
   8 │         k;
   9 │     } catch {
  10 │         overflow => { _; }
     ·                       ^
  11 │         _ => { 0; }
  12 │     };
  [128]

The deprecated legacy try/catch instructions keep their braced arms under the
try_legacy keyword (each arm produces the try's result; no `&` forms), and a
legacy-instruction module round-trips through it identically.

  $ wax --validate legacy.wax -f wat
  (tag $oops (param i32))
  (func $f (param $k i32) (result i32)
    (try (result i32)
      (do (local.get $k))
      (catch $oops)
      (catch_all (i32.const 0)))
  )
  $ wax legacy.wat -f wax
  tag oops(i32);
  fn f(k: i32) -> i32 {
      try_legacy {
          k;
      } catch {
          oops => {}
          _ => {
              0;
          }
      }
  }
  $ wax legacy.wat -f wax | wax -i wax -f wat -o legacy2.wat
  $ wax legacy.wat -f wat -o legacy1.wat
  $ diff legacy1.wat legacy2.wat
