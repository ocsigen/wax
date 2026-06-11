Source comments are preserved when converting Wax to WAT. The comment
delimiters are translated from Wax syntax (// and /* */) to WAT syntax (;; and
(; ;)), and each comment is emitted once even though conversion expands a Wax
instruction into several WebAssembly instructions.

  $ wax in.wax -f wat -o out.wat && cat out.wat
  ;; A leading comment on the function
  (func $add (param $a i32) (param $b i32) (result i32)
    (i32.add (local.get $a) (local.get $b))
  )
  
  ;; A comment between definitions
  (global $answer i32 (i32.const 42))
  ;; A trailing comment at the end of the file

