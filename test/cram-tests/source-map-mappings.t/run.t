Source-map correctness beyond the JSON shape (see source-map.t for that): the
`mappings` field is a hand-rolled base64-VLQ stream, so compile a multi-line
function and *decode* it, checking the arithmetic rather than pinning a golden
string. A golden would fix the bytes but not prove they decode to sane
positions, and — since every delta in a tiny module is non-negative — would
never exercise the VLQ sign bit.

`poly` spans several lines, so consecutive instructions map back and forth across
columns and lines, which forces negative column deltas (the sign-bit path):

  $ wax sm.wax -f wasm -o sm.wasm --source-map

Decode every segment and assert the invariants: it parses, generated offsets are
strictly increasing (one mapping per instruction — no two mappings on the same
byte), every mapping lands in the single source file within its line/column
bounds (a wrong VLQ delta would resolve out of bounds), and at least one
negative column delta was decoded.

  $ python3 - <<'PY'
  > import json
  > B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  > IDX = {c: i for i, c in enumerate(B64)}
  > m = json.load(open("sm.wasm.map"))
  > src = open(m["sources"][0]).read().split("\n")
  > def dec(seg):
  >     out, shift, val = [], 0, 0
  >     for ch in seg:
  >         d = IDX[ch]; cont = d & 32; d &= 31; val += d << shift
  >         if cont:
  >             shift += 5
  >         else:
  >             out.append(-(val >> 1) if val & 1 else val >> 1)
  >             shift, val = 0, 0
  >     return out
  > segs = [dec(s) for s in m["mappings"].split(",") if s]
  > gen = fidx = line = col = 0
  > offs, neg_col, onefile, bounds = [], False, True, True
  > for s in segs:
  >     gen += s[0]; offs.append(gen)
  >     if len(s) >= 4:
  >         fidx += s[1]; line += s[2]
  >         if s[3] < 0: neg_col = True
  >         col += s[3]
  >         if fidx != 0: onefile = False
  >         if not (0 <= line < len(src)) or not (0 <= col <= len(src[line])):
  >             bounds = False
  > mono = all(offs[i] < offs[i + 1] for i in range(len(offs) - 1))
  > ok = lambda b: "OK" if b else "FAIL"
  > print("mappings decode:", "OK")
  > print("generated offsets strictly increasing:", ok(mono))
  > print("all mappings in source file 0:", ok(onefile))
  > print("all positions within source bounds:", ok(bounds))
  > print("negative column delta exercised:", ok(neg_col))
  > PY
  mappings decode: OK
  generated offsets strictly increasing: OK
  all mappings in source file 0: OK
  all positions within source bounds: OK
  negative column delta exercised: OK
