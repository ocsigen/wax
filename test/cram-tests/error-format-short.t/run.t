--error-format=short renders each diagnostic as one
`file:line:col: severity: message` line (gcc/rustc style), on stderr, for an
editor with a line-based error parser (Vim's errorformat, Emacs Flymake, …).
The column is 1-based, matching the human location line. Exit codes are
unchanged.

A type error, in short form (still exit 128):

  $ wax check --error-format=short bad.wax
  bad.wax:1:17: error: Expecting type 'i32' but got type 'float'.
  [128]

A warning (an unused local) carries its severity and its -W name in brackets;
exit stays 0:

  $ wax check --error-format=short unused.wax
  unused.wax:1:21: warning: The local variable 'x' is never used. [unused-local]

An unknown format is rejected:

  $ NO_COLOR=1 wax check --error-format=bogus bad.wax
  Usage: wax check [--help] [OPTION]… FILE…
  wax: option '--error-format': Unknown error format: bogus
  [124]
