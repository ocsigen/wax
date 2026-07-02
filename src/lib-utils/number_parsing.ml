(* Compare two number literals by their significant digits alone, ignoring sign,
   radix point, digit separators and the exponent. Used to break a rounding tie
   between two literals known to have the same magnitude. *)

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

(* The significant digits of the double [az] (a rounding tie's midpoint), in the
   same radix as the literal [s], so [compare_mantissa_str] can compare them. *)
let midpoint_string hex s az =
  if not hex then Printf.sprintf "%.*g" (String.length s) az
  else
    let open Int64 in
    let bits = bits_of_float az in
    let mantissa =
      logor (logand bits 0xf_ffff_ffff_ffffL) 0x10_0000_0000_0000L
    in
    let i = skip_zeroes (String.uppercase_ascii s) 0 in
    if i = String.length s then Printf.sprintf "%.*g" (String.length s) az
    else
      (* Shift the mantissa so its msb lands in the most significant hex digit. *)
      let sh =
        match s.[i] with '1' -> 0 | '2' .. '3' -> 1 | '4' .. '7' -> 2 | _ -> 3
      in
      Printf.sprintf "%Lx" (shift_left mantissa sh)

(* Round the value of the literal [s] to the nearest 32-bit float, returned as a
   64-bit float that narrows to that f32 (with [Int32.bits_of_float]).

   Parsing to a double first and narrowing double-rounds: a decimal that lands
   exactly on an f32 midpoint would be resolved by ties-to-even against the
   *double*, which can disagree with the correctly-rounded f32 of the true
   value. We detect that case — the double [az] equals the exact midpoint
   between the two bracketing f32 values — and break the tie by comparing the
   literal's digits against the midpoint's, so the result matches a single
   correctly-rounded decimal->f32 step. This handles the normal, subnormal and
   overflow ranges uniformly (the midpoint of the max-finite/infinity pair is
   [2^128], the value at which round-to-nearest tips to overflow). *)
let float32_of_string s =
  let z = float_of_string s in
  if (not (Float.is_finite z)) || z = 0.0 then z
  else
    let neg = z < 0.0 in
    let az = Float.abs z in
    let f = Int32.bits_of_float az in
    let fz = Int32.float_of_bits f in
    let mag =
      if az = fz then az (* [az] is exactly an f32 *)
      else
        (* [az] lies strictly between [fz] (the nearest f32) and its neighbour
           one ULP toward [az]; for a non-negative value the bit pattern grows
           with the magnitude. *)
        let other = if az > fz then Int32.add f 1l else Int32.sub f 1l in
        let fo = Int32.float_of_bits other in
        let m =
          if Float.is_finite fz && Float.is_finite fo then (fz +. fo) *. 0.5
          else
            (* The neighbour is +inf: the rounding boundary is [max_finite +
               half an ULP = 0x1.ffffffp127] (i.e. [2^128 - 2^103]), the value
               at and above which round-to-nearest overflows to infinity. *)
            0x1.ffffffp127
        in
        if az <> m then az (* not a tie: [f] is already correctly rounded *)
        else
          let hex = String.contains s 'x' in
          match compare_mantissa_str hex s (midpoint_string hex s az) with
          | 0 -> az (* the literal is exactly the midpoint: ties-to-even *)
          | c when c > 0 ->
              Float.max fz fo (* |x| > midpoint: larger neighbour *)
          | _ -> Float.min fz fo (* |x| < midpoint: smaller neighbour *)
    in
    if neg then -.mag else mag

(* The exact 32-bit pattern of an f32 literal, preserving a signaling NaN's
   payload: a [nan:0x...] literal is assembled into bits directly (routing a NaN
   through an OCaml [float] would quiet it, as widening single->double sets the
   quiet bit); any other value is correctly rounded to f32 by
   [float32_of_string] and then reinterpreted. *)
let float32_bits s =
  let len = String.length s in
  let has_sign = len > 0 && (s.[0] = '-' || s.[0] = '+') in
  let offset = if has_sign then 1 else 0 in
  if len > offset + 4 && String.sub s offset 4 = "nan:" then
    let payload =
      Int64.of_string (String.sub s (offset + 4) (len - offset - 4))
    in
    let sign = if s.[0] = '-' then 0x80000000l else 0l in
    Int32.logor
      (Int32.logor sign 0x7F800000l) (* sign | exponent (all ones) *)
      (Int64.to_int32 (Int64.logand payload 0x7FFFFFL))
  else Int32.bits_of_float (float32_of_string s)

let float64 s =
  let len = String.length s in
  let has_sign = len > 0 && (s.[0] = '-' || s.[0] = '+') in
  let offset = if has_sign then 1 else 0 in
  if len > offset + 4 && String.sub s offset 4 = "nan:" then
    let payload =
      Int64.of_string (String.sub s (offset + 4) (len - offset - 4))
    in
    let sign_bit = if s.[0] = '-' then 1L else 0L in
    let bits =
      Int64.logor
        (Int64.logor
           (Int64.shift_left sign_bit 63)
           (Int64.shift_left 0x7FFL 52))
        (Int64.logand payload 0xFFFFFFFFFFFFFL)
    in
    Int64.float_of_bits bits
  else float_of_string s

let int_conv conv s = try conv s with Failure _ -> conv ("0u" ^ s)
let int32 s = int_conv Int32.of_string s
let int64 s = int_conv Int64.of_string s
