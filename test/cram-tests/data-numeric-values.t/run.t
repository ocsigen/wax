The WAT numeric-values proposal: a data segment's contents may mix string
literals with typed numeric runs. A run states its element type once —
[type: values] for scalars, [v128: shape(lanes), …] for vectors — so nan/inf are
ordinary values and nothing carries a per-element suffix.

A Wax data segment with numeric runs lowers to WAT numlists (runs preserved):

  $ cat > d.wax <<'EOF'
  > memory mem: i32 [1];
  > data seg = "abcd", [i16: -1], [f32: 0.2, nan, inf];
  > data seg2 @ mem[0] = [i8: 1, 2, 3, 4], "xy";
  > data vecs = [v128: i32x4(1, 2, 3, 4), f64x2(1.0, 2.0)];
  > EOF
  $ wax -f wat d.wax
  (memory $mem 1)
  (data $seg "abcd" (i16 -1) (f32 0.2 nan inf))
  (data $seg2 (memory $mem) (i32.const 0) (i8 1 2 3 4) "xy")
  (data $vecs (v128 i32x4 1 2 3 4 f64x2 1.0 2.0))

Lowered to the binary and read back, the runs are the same little-endian bytes
as the equivalent escaped strings:

  $ cat > b.wax <<'EOF'
  > memory mem: i32 [1];
  > data seg = "abcd", [i16: -1], [f32: 0.2, 0.3, 0.4];
  > EOF
  $ wax -f wasm b.wax -o b.wasm && wax -i wasm -f wat b.wasm
  (memory $mem 1)
  (data $seg "\61\62\63\64\ff\ff\cd\cc\4c\3e\9a\99\99\3e\cd\cc\cc\3e")

A WAT module written with numlists round-trips back to Wax runs. Because the
type is stated once, nan/inf carry no suffix, and a grouped v128 element stays
one run:

  $ cat > n.wat <<'EOF'
  > (module
  >   (memory $mem 1)
  >   (data $seg "abcd" (i16 -1) (f32 0.2 nan inf))
  >   (data (f32 nan nan))
  >   (data (v128 i32x4 1 2 3 4 i64x2 5 6)))
  > EOF
  $ wax -i wat -f wax n.wat
  memory mem: i32 [1];
  data seg = "abcd", [i16: -1], [f32: 0.2, nan, inf];
  data d = [f32: nan, nan];
  data d_2 = [v128: i32x4(1, 2, 3, 4), i64x2(5, 6)];

An empty segment omits the initializer entirely:

  $ cat > em.wax <<'EOF'
  > memory mem: i32 [1];
  > data d @ mem[0];
  > data p;
  > EOF
  $ wax -f wax em.wax
  memory mem: i32 [1]; data d @ mem [0]; data p;

A run element out of range is rejected:

  $ echo 'data a = [i8: 300];' | wax -f wat -i wax
  Error: This value is out of range for the data run's element type 'i8'.
   ──➤  -:1:15
  1 │ data a = [i8: 300];
    ·               ^^^
  2 │ 
  [128]


A run needs a scalar (or v128) element type:

  $ echo 'data c = [foo: 1, 2];' | wax -f wat -i wax
  Error:
    A data numeric run needs a scalar element type (i8, i16, i32, i64, f32, or
    f64).
   ──➤  -:1:11
  1 │ data c = [foo: 1, 2];
    ·           ^^^
  2 │ 
  [128]


A v128 lane group with the wrong lane count is rejected:

  $ echo 'data v = [v128: i32x4(1, 2, 3)];' | wax -f wat -i wax
  Error: This v128 lane group must have 4 lanes.
   ──➤  -:1:17
  1 │ data v = [v128: i32x4(1, 2, 3)];
    ·                 ^^^^^^^^^^^^^^
  2 │ 
  [128]

