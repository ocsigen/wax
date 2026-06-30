An integer literal whose magnitude exceeds the 32-bit range cannot be i32, so it
is given the LargeInt lattice type and defaults to i64 (rather than overflowing
i32). A literal that fits i32 still defaults to i32. The negative bound
(-2^63) is a negation of 2^63, which only i64 can hold.

  $ wax -i wax -f wat large.wax
  (func $unconstrained
    (drop (i64.const 82586009202572527))
    (drop (i64.const -9223372036854775808))
    (drop (i32.const 5))
  )
