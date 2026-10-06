(* Whether [s] is a valid Wax identifier. Called once per name during
   Wasm-to-Wax name assignment (thousands of times on a large module), so it must
   not allocate: a manual UTF-8 scan replaces the old [Sedlexing.Utf8.from_string]
   + [match%sedlex], which built a fresh lexbuf (and its refill buffer) per call.
   It fuses the coarse structural rule the sedlex [ident] regexp enforced with the
   strict XID check {!invalid_identifier_char} did separately: an ASCII scalar must be
   an identifier character in the right position; a non-ASCII scalar must satisfy
   [XID_Start] (first) or [XID_Continue] (rest) — the coarse rule admitted any
   non-ASCII scalar and the XID check then narrowed it, so requiring XID directly
   is equivalent. A leading ['_'] needs at least one further character, matching
   the regexp's [ '_', Plus id_cont_c ] alternative. *)
let is_valid s =
  let n = String.length s in
  let ascii_start c =
    (c >= Char.code 'a' && c <= Char.code 'z')
    || (c >= Char.code 'A' && c <= Char.code 'Z')
  in
  let ascii_cont c =
    ascii_start c
    || (c >= Char.code '0' && c <= Char.code '9')
    || c = Char.code '_'
    || c = Char.code '\''
  in
  let rec cont i =
    if i >= n then true
    else
      let d = String.get_utf_8_uchar s i in
      if not (Uchar.utf_decode_is_valid d) then false
      else
        let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
        let ok = if c < 0x80 then ascii_cont c else Xid.is_xid_continue c in
        ok && cont (i + Uchar.utf_decode_length d)
  in
  n > 0
  &&
  let d = String.get_utf_8_uchar s 0 in
  Uchar.utf_decode_is_valid d
  &&
  let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
  let len = Uchar.utf_decode_length d in
  if c < 0x80 then
    if c = Char.code '_' then len < n && cont len else ascii_start c && cont len
  else Xid.is_xid_start c && cont len
