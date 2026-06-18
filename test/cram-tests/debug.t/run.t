The --debug timing category logs the wall-clock running time of each compiler
pass to stderr, one line per pass as it finishes. The timing values vary from
run to run, so they are normalized here; only the labels and their order are
checked.

  $ wax input.wax -f wat --debug timing 2>&1 >/dev/null | sed 's/[0-9.]* ms/<t> ms/'
  parse: <t> ms
  type-check: <t> ms
  convert: <t> ms
  output: <t> ms

Categories are repeatable and may be comma-separated; an unknown category is
rejected with the list of valid ones.

  $ wax input.wax -f wat --debug bogus 2>&1 >/dev/null | tr '\n' ' ' | tr -s ' ' | grep -o 'Unknown debug category.*timing)'
  Unknown debug category: bogus (expected one of: timing)

The normal output on stdout is unchanged by --debug timing.

  $ wax input.wax -f wat > plain.wat
  $ wax input.wax -f wat --debug timing > debug.wat 2>/dev/null
  $ diff plain.wat debug.wat && echo identical
  identical
