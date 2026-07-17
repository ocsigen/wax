An inline function signature that duplicates an explicit declared type must reuse
it rather than mint a fresh implicit type, even when one side references a type by
number and the other by name. Here `$a`'s inline `(param (ref 0))` is the same
type as `$ft_s`'s `(param (ref $s))` (index 0 is `$s`); if `heaptype_eq` failed
to equate `(ref 0)` with `(ref $s)` it would mint a spurious implicit type,
shifting the numeric `(type 2)` reference in `$g` from `f64` to `(ref $s)`.

  $ cat > f.wat <<'WAT'
  > (module
  >   (type $s (struct))
  >   (type $ft_s (func (param (ref $s))))
  >   (func $a (param (ref 0)) unreachable)
  >   (func $b (param f64) unreachable)
  >   (func $g (type 2) unreachable))
  > WAT

`$g` keeps its declared signature `fn(f64)` (a spurious implicit type would make
it `fn(&s)`):

  $ wax -i wat -f wax f.wat
  type s = { };
  type ft_s = fn(&s);
  fn a(&s) {
      unreachable;
  }
  fn b(f64) {
      unreachable;
  }
  fn g(f64) {
      unreachable;
  }

It round-trips back to valid WebAssembly:

  $ wax -i wat -f wax f.wat | wax -i wax -f wasm -v -W unused=hidden -o /dev/null && echo OK
  OK
