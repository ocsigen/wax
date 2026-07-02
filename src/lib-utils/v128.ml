type shape = I8x16 | I16x8 | I32x4 | I64x2 | F32x4 | F64x2
type t = { shape : shape; components : string list }

let to_string v =
  let buffer = Bytes.create 16 in
  let components = v.components in
  (match v.shape with
  | I8x16 ->
      List.iteri
        (fun i n -> Bytes.set_uint8 buffer i (int_of_string n))
        components
  | I16x8 ->
      List.iteri
        (fun i n -> Bytes.set_int16_le buffer (i * 2) (int_of_string n))
        components
  | I32x4 ->
      List.iteri
        (fun i n -> Bytes.set_int32_le buffer (i * 4) (Number_parsing.int32 n))
        components
  | I64x2 ->
      List.iteri
        (fun i n -> Bytes.set_int64_le buffer (i * 8) (Number_parsing.int64 n))
        components
  | F32x4 ->
      List.iteri
        (fun i f ->
          Bytes.set_int32_le buffer (i * 4) (Number_parsing.float32_bits f))
        components
  | F64x2 ->
      List.iteri
        (fun i f ->
          Bytes.set_int64_le buffer (i * 8)
            (Int64.bits_of_float (Number_parsing.float64 f)))
        components);
  Bytes.to_string buffer

let of_string bytes =
  (* Default to i8x16 for now, or use a heuristic/parameter *)
  let len = String.length bytes in
  if len <> 16 then failwith "Invalid v128 length";
  let get_byte i = Char.code (String.get bytes i) in
  let rec loop i acc =
    if i < 0 then acc else loop (i - 1) (Int.to_string (get_byte i) :: acc)
  in
  { shape = I8x16; components = loop 15 [] }
