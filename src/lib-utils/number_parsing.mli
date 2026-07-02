val int32 : string -> int32
val int64 : string -> int64
val float64 : string -> float

val float32_bits : string -> int32
(** [float32_bits s] is the exact 32-bit pattern of the f32 literal [s]. It is
    correctly rounded (a single decimal->f32 rounding, avoiding the double
    rounding of parsing to a [double] and narrowing) and preserves a signaling
    NaN's payload (which routing the value through an OCaml [float] would
    quiet). *)
