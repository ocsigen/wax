A struct.new/struct.get/struct.set whose type index names a non-struct type
(here a func type) is invalid. A text input is validated before it is converted,
so validation rejects it here. (The decompiler also keeps a backstop for the
trusted binary-input path: it looks the fields up in a table holding only struct
types, and a miss used to raise Not_found -- an uncaught exception -- rather than
reporting a conversion error.)

  $ wax -i wat -f wax bad.wat -o /dev/null
  Error: Type '$f' should be a struct type.
   ──➤  bad.wat:4:16
  2 │   (type $f (func))
  3 │   (func (result (ref $f))
  4 │     struct.new $f))
    ·                ^^
  5 │ 
  [128]
