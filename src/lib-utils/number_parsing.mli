val int32 : string -> int32
val int64 : string -> int64
val float32 : string -> float
val float64 : string -> float

val float32_bits : string -> int32
(** [float32_bits s] is the exact 32-bit pattern of the f32 literal [s],
    preserving a signaling NaN's payload (which [float32] would quiet by routing
    the value through an OCaml [float]). *)
