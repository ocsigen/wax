let tab_width pos = 8 - (pos land 7)

let char_width pos u =
  let c = Uchar.to_int u in
  if c = 9 (* Tab *) then tab_width pos else Unicode_widths.get_width c

let terminal_width ?(offset = 0) s =
  let rec loop acc i len =
    if i >= len then acc
    else
      let dec = String.get_utf_8_uchar s i in
      let u = Uchar.utf_decode_uchar dec in
      let acc = acc + char_width (acc + offset) u in
      loop acc (i + Uchar.utf_decode_length dec) len
  in
  loop 0 0 (String.length s)

let expand_tabs ?(offset = 0) s =
  if not (String.contains s '\t') then s
  else
    let buf = Buffer.create 160 in
    let rec loop pos i len =
      if i < len then (
        if s.[i] = '\t' then (
          let n = tab_width pos in
          for _ = 1 to n do
            Buffer.add_char buf ' '
          done;
          loop (pos + n) (i + 1) len)
        else
          let dec = String.get_utf_8_uchar s i in
          let l = Uchar.utf_decode_length dec in
          Buffer.add_substring buf s i l;
          let u = Uchar.utf_decode_uchar dec in
          let pos = pos + char_width pos u in
          loop pos (i + l) len)
    in
    loop offset 0 (String.length s);
    Buffer.contents buf

let utf16_code_units s =
  let n = String.length s in
  let rec loop i acc =
    if i >= n then List.rev acc
    else
      let d = String.get_utf_8_uchar s i in
      let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
      let i = i + Uchar.utf_decode_length d in
      if c < 0x10000 then loop i (c :: acc)
      else
        let c = c - 0x10000 in
        loop i ((0xDC00 lor (c land 0x3FF)) :: (0xD800 lor (c lsr 10)) :: acc)
  in
  loop 0 []

let utf16_decode units =
  let b = Buffer.create (List.length units) in
  let rec decode = function
    | [] -> Some (Buffer.contents b)
    | hi :: lo :: rest when hi land 0xFC00 = 0xD800 && lo land 0xFC00 = 0xDC00
      ->
        let c = 0x10000 + ((hi land 0x3FF) lsl 10) + (lo land 0x3FF) in
        Buffer.add_utf_8_uchar b (Uchar.of_int c);
        decode rest
    | u :: rest when u < 0xD800 || u > 0xDFFF ->
        Buffer.add_utf_8_uchar b (Uchar.of_int u);
        decode rest
    | _ -> None
  in
  decode units

let scalar_of_hex s =
  match int_of_string_opt ("0x" ^ s) with
  | Some n when Uchar.is_valid n -> Some (Uchar.unsafe_of_int n)
  | _ -> None

(* Whether [s] contains a control character that a readable rendering would
   have to emit as a [\HH] hex escape (anything below U+0020 other than tab,
   newline and carriage return, or U+007F). In valid UTF-8 such code points are
   always single ASCII bytes, so we can scan the bytes directly. *)
let has_hex_escape s =
  String.exists
    (fun c ->
      let c = Char.code c in
      (c < 32 && c <> 9 (* '\t' *) && c <> 10 (* '\n' *) && c <> 13 (* '\r' *))
      || c = 127)
    s

let escape_string s =
  let b = Buffer.create (String.length s + 2) in
  if String.is_valid_utf_8 s && not (has_hex_escape s) then
    (* Valid UTF-8 with no character needing a hex escape: keep it readable,
       escaping only the quote and the backslash. *)
    let rec loop i len =
      if i < len then (
        let dec = String.get_utf_8_uchar s i in
        let u = Uchar.utf_decode_uchar dec in
        let c = Uchar.to_int u in
        (if c >= 32 && c <> 127 && c <> 34 (* '"' *) && c <> 92 (* '\\' *) then
           Buffer.add_utf_8_uchar b u
         else
           match Char.chr c with
           | '\t' -> Buffer.add_string b "\\t"
           | '\n' -> Buffer.add_string b "\\n"
           | '\r' -> Buffer.add_string b "\\r"
           | '"' -> Buffer.add_string b "\\\""
           | '\\' -> Buffer.add_string b "\\\\"
           | _ -> Printf.bprintf b "\\%02x" c);
        loop (i + Uchar.utf_decode_length dec) len)
    in
    loop 0 (String.length s)
  else
    (* Not valid UTF-8: this is binary data, so dump every byte as a [\HH]
       escape rather than interleaving decoded text with byte escapes. *)
    String.iter (fun c -> Printf.bprintf b "\\%02x" (Char.code c)) s;
  let s' = Buffer.contents b in
  (terminal_width s', s')
