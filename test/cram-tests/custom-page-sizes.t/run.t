A memory may declare a custom page size with a [pagesize N] clause after its
limits (the page size is the byte value 1 or 65536, matching the WAT
[(pagesize N)] form). It lowers to WAT and validates.

  $ wax --validate mem.wax -f wat
  (memory $small (export "small") 4096 (pagesize 1))
  
  (memory $big 2 4 (pagesize 65536))
  
  (memory $def (export "def") 1)

A WebAssembly module using custom page sizes decompiles back to the same
[pagesize] clause.

  $ wax roundtrip.wat -f wax
  #[export]
  memory small: i32 [4096] pagesize 1;
  memory m: i32 [2, 4] pagesize 65536;

The page size must be 1 or 65536; another power of two is rejected.

  $ wax check bad-value.wax
  Error: The custom page size must be 1 or 65536.
   ──➤  bad-value.wax:1:1
  1 │ memory m: i32 [1] pagesize 4;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

A value that is not a power of two is rejected while parsing.

  $ wax check bad-pow2.wax
  Error: The page size must be a power of two.
   ──➤  bad-pow2.wax:1:28
  1 │ memory m: i32 [1] pagesize 3;
    ·                            ^
  2 │ 
  [128]

A page size larger than [max_int] is still parsed by its base-2 logarithm (it
is a power of two) rather than overflowing the narrowing to [int], so it is
rejected by the 1-or-65536 check like any other unsupported size (its large
exponent also trips the memory-size bound) instead of crashing.

  $ wax check huge-pow2.wax
  Error: The custom page size must be 1 or 65536.
   ──➤  huge-pow2.wax:1:1
  1 │ memory m: i32 [1] pagesize 9223372036854775808;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: The memory size is too large. It should be less than 0x0.
   ──➤  huge-pow2.wax:1:1
  1 │ memory m: i32 [1] pagesize 9223372036854775808;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

With a page size of 1, the page count may run up to 2^32 - 1; one more is
rejected (the byte span still bounds it).

  $ wax check too-big.wax
  Error: The memory size is too large. It should be less than 0xffffffff.
   ──➤  too-big.wax:1:1
  1 │ memory m: i32 [4294967296] pagesize 1;
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]
