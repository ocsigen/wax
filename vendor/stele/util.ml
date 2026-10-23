(* Small shared helpers. *)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)
module IntSet = Set.Make (Int)

(* Does [s] contain [sub] as a substring? *)
let contains_sub s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i = i + lsub <= ls && (String.sub s i lsub = sub || go (i + 1)) in
  go 0

(* The base head of a (possibly parameterized) symbol: the text before the first
   '(' ([function_type(in_type)] -> [function_type], [option(ID)] -> [option]).
   An unparameterized symbol is returned unchanged. *)
let base_symbol_name s =
  match String.index_opt s '(' with Some i -> String.sub s 0 i | None -> s

(* The [entry_point: sentence] header that keys an entry: in menhir's
   [.messages] file, in the [.overrides] file, and in the sorted golden. *)
let header_of (e : Parse_messages.entry) = e.entry_point ^ ": " ^ e.sentence
