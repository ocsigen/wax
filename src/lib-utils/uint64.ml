type t = Int64.t

let of_string s =
  try
    if String.starts_with ~prefix:"0x" s then Int64.of_string s
    else Int64.of_string ("0u" ^ s)
  with Failure _ as e ->
    Format.eprintf "Unsigned int overflow: %s@." s;
    raise e

(* Avoid [Printf.sprintf "%Lu"], whose [camlinternalFormat] interpreter is a
   heavy per-call allocation on this output-rendering path. A non-negative
   [Int64] already reads as its unsigned self via the lightweight [Int64.to_string]
   primitive; only a top-bit-set value (unsigned >= 2^63, rare) needs the format
   interpreter. *)
let to_string s =
  if Int64.compare s 0L >= 0 then Int64.to_string s else Printf.sprintf "%Lu" s

let of_int i = Int64.of_int i

(* Every caller must first bound the value so it is known to fit an OCaml [int]
   (see [.mli]): an unguarded call that overflows is a bug at the call site, not
   a condition to recover from here. *)
let to_int i =
  match Int64.unsigned_to_int i with Some i -> i | None -> assert false

let to_int64 i = i
let of_int64 i = i
let zero = 0L
let one = 1L
let compare = Int64.unsigned_compare
