A function whose inline signature disagrees with its type reference is invalid.
When the reference names a concrete type (here an exact struct reference), the
mismatch error must render the definition from its *declared source* — the
resolved function type carries no source name for a concrete reference, so
reconstructing it via [source_of_valtype] used to hit [source_of_heaptype]'s
[assert false] and crash. It is now rejected cleanly:

  $ wax check -X custom-descriptors=on mismatch.wat
  Error:
    The inline function type does not match the type definition, whose
    parameters are '[(ref (exact $s))]' and results are '[i32]'.
   ──➤  mismatch.wat:4:15
  2 │   (type $s (struct))
  3 │   (type $ft (func (param (ref (exact $s))) (result i32)))
  4 │   (func (type $ft) (param (ref $s)) (result i32)
    ·               ^^^
  5 │     unreachable))
  6 │ 
  [128]
