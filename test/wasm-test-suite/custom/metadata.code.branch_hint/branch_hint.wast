(module
  (type (;0;) (func (param i32)))
  (memory (;0;) 1 1)
  (func $dummy)
  (func $test1 (type 0)
    (local i32)
    local.get 1
    local.get 0
    i32.eq
    (@metadata.code.branch_hint "\00" ) if
      return
    end
    return
  )
  (func $test2 (type 0)
    (local i32)
    local.get 1
    local.get 0
    i32.eq
    (@metadata.code.branch_hint "\01" ) if
      return
    end
    return
  )
  (func (export "nested") (param i32 i32) (result i32)
    (@metadata.code.branch_hint "\00")
    (if (result i32) (local.get 0)
      (then
        (if (local.get 1) (then (call $dummy) (block) (nop)))
        (if (local.get 1) (then) (else (call $dummy) (block) (nop)))
        (@metadata.code.branch_hint "\01")
        (if (result i32) (local.get 1)
          (then (call $dummy) (i32.const 9))
          (else (call $dummy) (i32.const 10))
        )
      )
      (else
        (if (local.get 1) (then (call $dummy) (block) (nop)))
        (@metadata.code.branch_hint "\00")
        (if (local.get 1) (then) (else (call $dummy) (block) (nop)))
        (if (result i32) (local.get 1)
          (then (call $dummy) (i32.const 10))
          (else (call $dummy) (i32.const 11))
        )
      )
    )
  )
)

(module binary
  "\00asm" "\01\00\00\00"
  "\01\85\80\80\80\00\01\60\01\7f\00"
  "\03\82\80\80\80\00\01\00\00"
  "\a0\80\80\80\00\19\6d\65\74\61\64\61\74\61\2e\63\6f\64\65\2e\62\72\61\6e\63\68\5f\68\69\6e\74\01\00\01\05\01\00"
  "\0a\8f\80\80\80\00\01\89\80\80\80\00\00\02\40\41\00\0d\00\0b\0b"
)

(assert_malformed_custom
  (module quote
    "(func $test2 (type 0)"
    "  (local i32)"
    "  local.get 1"
    "  local.get 0"
    "  i32.eq"
    "  (@metadata.code.branch_hint \"\\01\" )"
    "  (@metadata.code.branch_hint \"\\01\" )"
    "  if"
    "    return"
    "  end"
    "  return"
    ")"
  )
  "@metadata.code.branch_hint annotation: duplicate annotation"
)
(assert_malformed_custom
  (module quote
    "(module"
    "  (@metadata.code.branch_hint \"\\01\" )"
    "  (type (;0;) (func (param i32)))"
    "  (memory (;0;) 1 1)"
    "  (func $test (type 0)"
    "    (local i32)"
    "    local.get 1"
    "    local.get 0"
    "    i32.eq"
    "    return"
    "  )"
    ")"
  )
  "@metadata.code.branch_hint annotation: not in a function"
)

(assert_invalid_custom
  (module
    (type (;0;) (func (param i32)))
    (memory (;0;) 1 1)
    (func $test (type 0)
      (local i32)
      local.get 1
      local.get 0
      (@metadata.code.branch_hint "\01" )
      i32.eq
      return
    )
  )
  "@metadata.code.branch_hint annotation: invalid target"
)
