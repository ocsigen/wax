The 'check' subcommand validates files (type-checking Wax, well-formedness for
Wasm) without producing output. Valid files pass silently:

  $ wax check ok.wax ok.wat

An invalid file is reported and the exit status is non-zero:

  $ wax check bad.wax
  Error: This expression has type 'float' but is expected to have type 'i32'.
   ──➤  bad.wax:1:17
  1 │ fn h() -> i32 { 1.0; }
    ·                 ^^^
  2 │ 
  [128]

Every file is checked; errors in several files are all reported before exiting:

  $ wax check ok.wax bad.wax
  Error: This expression has type 'float' but is expected to have type 'i32'.
   ──➤  bad.wax:1:17
  1 │ fn h() -> i32 { 1.0; }
    ·                 ^^^
  2 │ 
  [128]

--format (-f) overrides the extension-based detection:

  $ cp bad.wax bad.txt
  $ wax check -f wax bad.txt
  Error: This expression has type 'float' but is expected to have type 'i32'.
   ──➤  bad.txt:1:17
  1 │ fn h() -> i32 { 1.0; }
    ·                 ^^^
  2 │ 
  [128]

A file whose format cannot be detected is reported:

  $ wax check no-extension
  no-extension: cannot detect format (expected .wat, .wax or .wasm)
  [128]
