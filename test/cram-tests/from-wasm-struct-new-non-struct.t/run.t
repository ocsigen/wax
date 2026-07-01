Decompiling a struct.new/struct.get/struct.set whose type index names a
non-struct type (here a func type) is invalid input that validation rejects.
from_wasm looks the fields up in a table holding only struct types; a miss used
to raise Not_found (an uncaught exception). Report it as a conversion error and
abort cleanly instead:

  $ wax -i wat -f wax bad.wat -o /dev/null
  Error: This type should be a struct type.
   ──➤  bad.wat:4:16
  2 │   (type $f (func))
  3 │   (func (result (ref $f))
  4 │     struct.new $f))
    ·                ^^
  5 │ 
  [128]
