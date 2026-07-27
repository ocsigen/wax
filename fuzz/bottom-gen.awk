# bottom-gen.awk — enumerate small function BODIES over a focused alphabet of
# bottom-typed producers and type-adaptive surfaces, for bottom-fuzz.sh. Each
# output line is ONE candidate body: its instructions joined by `|` (the driver
# splits on `|` into one unfolded WAT instruction per line and drops it into a
# fixed scaffolding module). `-v count=N` appends N random-depth tail candidates;
# `-v seed=S` seeds that tail. The exhaustive core needs no seed.
#
# Why this alphabet: every recent round-trip bug was a tiny composition of a
# bottom-typed value (a hole `_`, a `ref.null`, an `unreachable` residue) with a
# type-adaptive surface (`select`, the `br_on_*` family, the hierarchy converts),
# sometimes with an interposed zero-effect statement (`atomic.fence`), in a live
# OR a post-`unreachable` position — every one <=6 instructions. So the core is a
# TEMPLATED enumeration shaped like that bug:
#
#     WRAP[  PRODUCER  ADAPTER  CONSUMER  SINK  ]WRAP
#
#   WRAP    — position/structure control, applied as a balanced pair around the
#             body: none / a leading `unreachable` (the dead-code arm) / a
#             `block … end` wrapper / a `loop … end` wrapper.
#   PRODUCER— pushes one bottom/ref/num/float value: `ref.null` at each heap type
#             in BOTH hierarchies (none/nofunc/extern/any/func), an i64/i32 const,
#             an f32/f64 const, the typed params/locals, a call.
#   ADAPTER — a ~1->1 type-adaptive or passthrough op, or a zero-effect
#             interposition (`atomic.fence`): the ref-null/non-null/cast branch
#             passthroughs, the non-null coercion, `ref.is_null`, i31 box/unbox,
#             the cross-hierarchy converts, the width-sensitive float methods
#             (`fN.sqrt/abs/ceil/floor/trunc/nearest`).
#   CONSUMER— the type-adaptive sinks: typed and untyped `select` (including
#             float-typed), `ref.eq`, the i64 width op `i64.shr_u`, `drop`, and
#             `br_on_cast`/`br_on_cast_fail` into BOTH hierarchies
#             (`(ref null func)`->`nofunc`, `anyref`->i31/none).
#   SINK    — a trailing nothing / `drop` / `unreachable`.
#
# WRAP is a balanced pair (a `block`/`loop` always gets its matching `end`) so no
# core candidate is structurally malformed — an unbalanced body neither tool can
# parse is a wasted slot, not coverage.
#
# The scaffolding module (in the driver) gives the body typed params/locals, a
# memory, and three named result-typed blocks ($bfunc:(ref null func),
# $bi31:(ref null i31), $bany:(ref null any)) so a `br`/`br_on_*` has a valid
# target in each hierarchy, plus a trailing `unreachable` so leftover stack never
# fails function-arity. Bodies need NOT type-check: the reference interpreter
# arbitrates validity (both-reject candidates are simply dropped), and the
# both-valid survivors are what the round-trip oracle then chews on. The leading
# `unreachable` WRAP arm is the only systematic way to reach the validator's
# dead-code / principal-typing arms — the class that hid the extern.convert_any
# and atomic.fence bugs — so position is a first-class slot.
#
# Depth beyond the core is left to the random tail (length 3..8), which composes
# the same alphabet freely (multiple adapters, adapter-first orders the template's
# slot roles exclude). Dedup is the driver's `sort -u` over these lines (a body IS
# its signature).

BEGIN {
  np = split("" \
    "ref.null none" SUBSEP "ref.null nofunc" SUBSEP "ref.null extern" SUBSEP \
    "ref.null any" SUBSEP "ref.null func" SUBSEP "i64.const 40" SUBSEP \
    "i32.const 1" SUBSEP "f32.const 1.0" SUBSEP "f64.const 1.0" SUBSEP \
    "local.get $r" SUBSEP "local.get $n" SUBSEP \
    "local.get $x" SUBSEP "local.get $b" SUBSEP "call $g", prod, SUBSEP)

  # adapters[1] is the empty slot (no adapter).
  na = split("" SUBSEP "ref.as_non_null" SUBSEP "ref.is_null" SUBSEP \
    "extern.convert_any" SUBSEP "any.convert_extern" SUBSEP "ref.i31" SUBSEP \
    "i31.get_s" SUBSEP "br_on_null $bany" SUBSEP "br_on_non_null $bany" SUBSEP \
    "atomic.fence" SUBSEP \
    "f32.sqrt" SUBSEP "f32.abs" SUBSEP "f32.ceil" SUBSEP \
    "f32.floor" SUBSEP "f32.trunc" SUBSEP "f32.nearest" SUBSEP \
    "f64.sqrt" SUBSEP "f64.abs" SUBSEP "f64.ceil" SUBSEP \
    "f64.floor" SUBSEP "f64.trunc" SUBSEP "f64.nearest", adapt, SUBSEP)

  # consumers[1] is the empty slot.
  nc = split("" SUBSEP "select" SUBSEP "select (result i64)" SUBSEP \
    "select (result f32)" SUBSEP "select (result f64)" SUBSEP \
    "select (result (ref null any))" SUBSEP "ref.eq" SUBSEP "i64.shr_u" SUBSEP \
    "drop" SUBSEP "br_on_cast $bfunc (ref null func) (ref nofunc)" SUBSEP \
    "br_on_cast_fail $bfunc (ref null func) (ref nofunc)" SUBSEP \
    "br_on_cast $bany (ref null any) (ref i31)" SUBSEP \
    "br_on_cast_fail $bany (ref null any) (ref none)", cons, SUBSEP)

  # WRAP is a balanced (open, close) pair. nwrap modes: none, leading
  # unreachable, block wrapper, loop wrapper.
  nwrap = split("" SUBSEP "unreachable" SUBSEP "block" SUBSEP "loop", wopen, SUBSEP)
  wclose[1] = ""; wclose[2] = ""; wclose[3] = "end"; wclose[4] = "end"
  nsink = split("" SUBSEP "drop" SUBSEP "unreachable", sink, SUBSEP)

  # ---- Exhaustive templated core. ----
  for (wi = 1; wi <= nwrap; wi++)
    for (bi = 1; bi <= np; bi++)
      for (ai = 1; ai <= na; ai++)
        for (ci = 1; ci <= nc; ci++)
          for (si = 1; si <= nsink; si++) {
            line = wopen[wi]
            add(prod[bi]); add(adapt[ai]); add(cons[ci]); add(sink[si])
            add(wclose[wi])
            if (line != "") print line
          }

  # ---- Random tail: length 3..8, free composition over the whole alphabet. ----
  # Pool = producers + non-empty adapters + non-empty consumers.
  npool = 0
  for (i = 1; i <= np; i++) pool[npool++] = prod[i]
  for (i = 2; i <= na; i++) pool[npool++] = adapt[i]
  for (i = 2; i <= nc; i++) pool[npool++] = cons[i]
  count = count + 0
  if (count > 0) {
    srand(seed)
    for (t = 0; t < count; t++) {
      len = 3 + int(rand() * 6)          # 3..8
      # A balanced wrapper (kept balanced so the tail is well-formed too).
      wi = int(rand() * nwrap) + 1
      line = wopen[wi]
      for (j = 0; j < len; j++) add(pool[int(rand() * npool)])
      add((rand() < 0.5) ? sink[int(rand() * nsink) + 1] : "")
      add(wclose[wi])
      if (line != "") print line
    }
  }
}

# Append token to the global `line`, `|`-joined, skipping empties.
function add(tok) {
  if (tok == "") return
  line = (line == "") ? tok : line "|" tok
}
