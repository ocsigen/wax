type ('desc, 'info) annotated = { desc : 'desc; info : 'info }
type location = { loc_start : Lexing.position; loc_end : Lexing.position }

let no_loc desc =
  { desc; info = { loc_start = Lexing.dummy_pos; loc_end = Lexing.dummy_pos } }

(* Concatenate the string payloads of an annotated list, e.g. the pieces of a
   multi-string [datastring] ([(data "a" "b")] / [(@string "a" "b")]). *)
let concat_desc l = String.concat "" (List.map (fun x -> x.desc) l)
