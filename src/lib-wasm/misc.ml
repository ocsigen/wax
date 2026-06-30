let is_hex c = ('0' <= c && c <= '9') || ('A' <= c && c <= 'F')
let is_exp hex c = c = if hex then 'P' else 'E'
let at_end hex s i = i = String.length s || is_exp hex s.[i]

let rec skip_non_hex s i =
  (* to skip sign, 'x', '.', '_', etc. *)
  if at_end true s i || is_hex s.[i] then i else skip_non_hex s (i + 1)

let rec skip_zeroes s i =
  let i' = skip_non_hex s i in
  if at_end true s i' || s.[i'] <> '0' then i' else skip_zeroes s (i' + 1)

let rec compare_mantissa_str' hex s1 i1 s2 i2 =
  let i1' = skip_non_hex s1 i1 in
  let i2' = skip_non_hex s2 i2 in
  match (at_end hex s1 i1', at_end hex s2 i2') with
  | true, true -> 0
  | true, false -> if at_end hex s2 (skip_zeroes s2 i2') then 0 else -1
  | false, true -> if at_end hex s1 (skip_zeroes s1 i1') then 0 else 1
  | false, false -> (
      match compare s1.[i1'] s2.[i2'] with
      | 0 -> compare_mantissa_str' hex s1 (i1' + 1) s2 (i2' + 1)
      | n -> n)

let compare_mantissa_str hex s1 s2 =
  let s1' = String.uppercase_ascii s1 in
  let s2' = String.uppercase_ascii s2 in
  compare_mantissa_str' hex s1' (skip_zeroes s1' 0) s2' (skip_zeroes s2' 0)

let float32_of_string s =
  (* First parse to a 64 bit float. *)
  let z = float_of_string s in
  (* If value is already infinite we are done. *)
  if abs_float z = 1.0 /. 0.0 then z
  else if abs_float z <= 0x1.fffffep+127 then z
  else
    (* Else, bit twiddling to see what rounding to target precision will do. *)
    let open Int64 in
    let bits = bits_of_float z in
    let lsb = shift_left 1L (52 - 23) in
    (* Check for tie, i.e. whether the bits right of target LSB are 10000... *)
    let tie = shift_right lsb 1 in
    let mask = lognot (shift_left (-1L) (52 - 23)) in
    (* If we have no tie, we are good. *)
    if logand bits mask <> tie then z
    else
      (* Else, define epsilon to be the value of the tie bit. *)
      let exp = float_of_bits (logand bits 0xfff0_0000_0000_0000L) in
      let eps = float_of_bits (logor tie (bits_of_float exp)) -. exp in
      (* Convert 64 bit float back to string to compare to input. *)
      let hex = String.contains s 'x' in
      let s' =
        if not hex then Printf.sprintf "%.*g" (String.length s) z
        else
          let m =
            logor (logand bits 0xf_ffff_ffff_ffffL) 0x10_0000_0000_0000L
          in
          (* Shift mantissa to match msb position in most significant hex digit *)
          let i = skip_zeroes (String.uppercase_ascii s) 0 in
          if i = String.length s then Printf.sprintf "%.*g" (String.length s) z
          else
            let sh =
              match s.[i] with
              | '1' -> 0
              | '2' .. '3' -> 1
              | '4' .. '7' -> 2
              | _ -> 3
            in
            Printf.sprintf "%Lx" (shift_left m sh)
      in
      (* - If mantissa became larger, float was rounded up to tie already;
       *   round-to-even might round up again: sub epsilon to round down.
       * - If mantissa became smaller, float was rounded down to tie already;
       *   round-to-even migth round down again: add epsilon to round up.
       * - If tie is not the result of prior rounding, then we are good.
       *)
      match compare_mantissa_str hex s s' with
      | -1 -> z -. eps
      | 1 -> z +. eps
      | _ -> z

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
  check_float s 23 (fun s ->
      float32_of_string s < 0x1.ffffffp127
      && float32_of_string s > -0x1.ffffffp127)

let is_float64 s = check_float s 52 (fun s -> Float.(is_finite (of_string s)))

(*ZZZ We could be smarter: if we have invalid UTF-8 character, use \xx
  for all characters *)
let escape_string s =
  let b = Buffer.create (String.length s + 2) in
  let rec loop b i len =
    if i < len then
      let dec = String.get_utf_8_uchar s i in
      if Uchar.utf_decode_is_valid dec then (
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
        loop b (i + Uchar.utf_decode_length dec) len)
      else (
        Printf.bprintf b "\\%02x" (Char.code s.[i]);
        loop b (i + 1) len)
  in
  loop b 0 (String.length s);
  let s' = Buffer.contents b in
  (Wax_utils.Unicode.terminal_width s', s')
