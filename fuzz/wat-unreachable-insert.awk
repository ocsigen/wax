# wat-unreachable-insert.awk — insert `unreachable` at ONE instruction boundary
# of an UNFOLDED WAT module (wax `--unfold` output). -v k=N picks the boundary
# (0-based); -v count=1 instead prints the number of boundaries. Reads WAT on
# stdin (or a file arg), writes the mutant to stdout.
#
# The metamorphic property behind the paired driver (unreachable-fuzz.sh):
# inserting `unreachable` at any instruction boundary of a valid module
# preserves validity — the code after it is dead and validates against the
# polymorphic stack, and local-initialization tracking is unaffected because no
# local.set is removed. So a mutant wax rejects is an over-rejection in the
# validator's dead-code / principal-typing arms (Bot/Bot_ref), the class behind
# the extern.convert_any/any.convert_extern unreachable over-rejection.
#
# A boundary is "before an instruction line at a (func ...) body level". wax's
# unfolded printer gives one instruction per line, indented, never starting with
# '(' (block headers, else/end included — all are instruction boundaries), while
# every non-instruction line ((local ...), (func ... headers, module fields,
# closing parens) starts with '(' or ')' or is at column 0.
#
# Track paren depth and the func body level so the boundary is a genuine body
# instruction, excluding two look-alikes that would make the mutant invalid
# rather than dead-code-extended:
#   - a constant initializer's body: `(global i32 <expr>)` / a segment offset is
#     also unfolded, so its instruction lines sit at the same indent as a func
#     body. A single-line `(func $f)` balances on its own line, so paren depth
#     (not a line-start heuristic) is what keeps `in_func` from leaking into a
#     following `(global ...)`.
#   - a wrapped signature: a long `(param ...)` / `(result ...)` prints one
#     valtype per line, deeper than the body, so gate on the exact body depth.
BEGIN { depth = 0 }
{
  start_depth = depth
  if (in_func && start_depth == body_level && $0 ~ /^[ \t]+[^ \t()]/) {
    if (count) n++
    else if (nb++ == k) {
      indent = $0; sub(/[^ \t].*$/, "", indent)
      print indent "unreachable"
    }
  }
  if (!count) print
  # A func opens at module level; its body instructions sit one paren deep.
  if ($0 ~ /^\(func([ (]|$)/) { in_func = 1; body_level = start_depth + 1 }
  opens = $0; closes = $0
  depth += gsub(/\(/, "", opens) - gsub(/\)/, "", closes)
  if (in_func && depth <= 0) in_func = 0
}

END { if (count) print n + 0 }
