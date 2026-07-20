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
# A boundary is "before an instruction line inside a (func ...) body". wax's
# unfolded printer gives one instruction per line, indented, never starting
# with '(' (block headers, else/end included — all are instruction boundaries),
# while every non-instruction line ((local ...), (func ... headers, module
# fields, closing parens) starts with '(' or ')' or is at column 0. Global and
# segment initializers are ALSO printed unfolded, so the func tracking matters:
# inserting into a constant expression would genuinely invalidate the module.

/^\(func([ (]|$)/ { in_func = 1 }
/^\)/             { in_func = 0 }

{
  if (in_func && $0 ~ /^[ \t]+[^ \t()]/) {
    if (count) n++
    else if (nb++ == k) {
      indent = $0; sub(/[^ \t].*$/, "", indent)
      print indent "unreachable"
    }
  }
  if (!count) print
}

END { if (count) print n + 0 }
