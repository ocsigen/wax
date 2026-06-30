# Seeded text mutator for WAT, driving the WAT-mutation fuzzer (mutate-wat.sh).
#
#   awk -v seed=N -f mutate-wat.awk file.wat   (mutated WAT to stdout)
#
# The WAT bugs we hunt live in the parser/lexer (raising conversions of numeric
# and escape literals), so — unlike the wax AST mutator, which targets the typer
# — text-level mutation that injects EDGE-VALUE literals is the right tool: it
# drops out-of-range numbers and over-long escapes straight into the positions
# the lexer/parser convert. One mutation per run, chosen by the seed:
#   * replace a numeric token with an out-of-range / edge value;
#   * inject an over-long \u{...} escape into a string;
#   * a structural perturbation (duplicate / delete a line) for variety.

BEGIN {
  srand(seed);
  ni = split("18446744073709551616 18446744073709551615 4294967296 4294967295 "\
             "0xffffffffffffffff 0x10000000000000000 99999999999999999999 "\
             "2147483648 0 1 -1 0x1_0000_0000", INT, " ");
  nf = split("1e999999 0x1p1000000 nan:0xffffffffffffff nan:0x0 inf -inf 1.0 0.0",
             FLT, " ");
}
{ line[NR] = $0 }
END {
  if (NR == 0) exit;
  r = int(rand() * 100);
  if (r < 45) {                       # replace a numeric token with an edge int
    edge(INT, ni);
  } else if (r < 75) {                # replace a numeric token with an edge float
    edge(FLT, nf);
  } else if (r < 90) {                # inject a long \u{...} escape into a string
    for (t = 0; t < NR * 3; t++) {
      L = int(rand() * NR) + 1;
      if (match(line[L], /"/)) {
        line[L] = substr(line[L], 1, RSTART) "\\u{ffffffffffffffffff}" \
                  substr(line[L], RSTART + 1);
        break;
      }
    }
  } else if (r < 95) {                # duplicate a line
    L = int(rand() * NR) + 1;
    dup[L] = 1;
  } else {                            # delete a line
    del = int(rand() * NR) + 1;
  }
  for (i = 1; i <= NR; i++) {
    if (i == del) continue;
    print line[i];
    if (i in dup) print line[i];
  }
}

# Replace a random STANDALONE numeric literal anywhere in the file with a value
# from pool P (np entries). Collect all candidates first, skipping digits that
# are part of an identifier/keyword (i32, v128, $3, 0x1.5 inner), so the edge
# value lands in a real literal position (a const value, memarg offset/align, an
# index, a lane) — exactly what the lexer/parser convert and could choke on.
function edge(P, np,    L, rest, base, abs, before, cn, c) {
  cn = 0;
  for (L = 1; L <= NR; L++) {
    rest = line[L]; base = 0;
    while (match(rest, /[0-9][0-9a-fA-FxXpP._+-]*/)) {
      abs = base + RSTART;                       # 1-based position in line[L]
      before = (abs > 1) ? substr(line[L], abs - 1, 1) : " ";
      if (before !~ /[0-9A-Za-z_$.]/) {
        cn++; CL[cn] = L; CA[cn] = abs; CE[cn] = RLENGTH;
      }
      base = abs + RLENGTH - 1;
      rest = substr(rest, RSTART + RLENGTH);
    }
  }
  if (cn == 0) return;
  c = int(rand() * cn) + 1; L = CL[c];
  line[L] = substr(line[L], 1, CA[c] - 1) P[int(rand() * np) + 1] \
            substr(line[L], CA[c] + CE[c]);
}
