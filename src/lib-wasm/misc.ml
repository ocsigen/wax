let rec is_int conv sub s =
  if String.starts_with ~prefix:"-0x" s then
    let s = String.sub s 1 (String.length s - 1) in
    is_int conv sub s
    &&
    let i = conv s in
    i >= conv "0" || sub i (conv "1") >= conv "0"
  else
    try
      ignore (conv s);
      true
    with Failure _ -> (
      try
        ignore (conv ("0u" ^ s));
        true
      with Failure _ -> false)

let is_int32 s = is_int Int32.of_string Int32.sub s
let is_int64 s = is_int Int64.of_string Int64.sub s

(* A valid i8/i16 value fits a *signed* Int32, so parse with [of_string_opt]: a
   value that [is_int32] accepts only via its unsigned (["0u"]) fallback (i.e. in
   the (i32-max, u32-max] range) fails the signed parse here and is correctly out
   of the i8/i16 range — rather than crashing [Int32.of_string]. *)
let is_int16 s =
  is_int32 s
  &&
  match Int32.of_string_opt s with
  | Some i -> i >= -32768l && i < 65536l
  | None -> false

let is_int8 s =
  is_int32 s
  &&
  match Int32.of_string_opt s with
  | Some i -> i >= -128l && i < 256l
  | None -> false

let check_float s w f =
  if String.length s <= 2 then f s
  else
    let i = if s.[0] = '+' || s.[0] = '-' then 1 else 0 in
    match s.[i] with
    | 'n' -> (
        String.length s = i + 3
        ||
          try
            let exp =
              Int64.of_string (String.sub s (i + 4) (String.length s - i - 4))
            in
            exp > 0L && exp < Int64.shift_left 1L w
          with Failure _ -> false)
    | 'i' -> true
    | _ -> f s

let is_float32 s =
  (* A finite literal is a valid f32 iff its correct rounding does not overflow
     to infinity (an explicit [inf]/[nan] is accepted by [check_float]). *)
  check_float s 23 (fun s ->
      Int32.logand (Wax_utils.Number_parsing.float32_bits s) 0x7fffffffl
      <> 0x7f800000l)

let is_float64 s = check_float s 52 (fun s -> Float.(is_finite (of_string s)))

let escape_string s =
  let b = Buffer.create (String.length s + 2) in
  if String.is_valid_utf_8 s then
    (* Valid UTF-8: keep it readable, escaping only the characters a WAT string
       literal cannot carry raw (controls, the quote and the backslash). *)
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
  (Wax_utils.Unicode.terminal_width s', s')
