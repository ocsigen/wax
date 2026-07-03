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
