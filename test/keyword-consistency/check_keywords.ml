(* A bare-word keyword of the Wax lexer must be registered in three places, two
   of which fail silently when forgotten:

   - [src/lib-wax/lexer.ml]        the keyword itself (source of truth)
   - [src/lib-wax/parser.mly]      [ident_or_keyword], so it still works as a label
   - [src/lib-conversion/namespace.ml] [reserved], so [from_wasm] renames a
                                    generated entity that would collide with it

   This test extracts the keyword set from the lexer and checks each one appears
   in the other two lists, so adding a keyword without updating them fails the
   build with the exact culprit named. It relies on the Wax lexer having no
   instruction-mnemonic keywords (unlike the Wasm lexer), so its bare lowercase
   arms are exactly the structural keywords. *)

let read_file f =
  let ic = open_in_bin f in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* Every capture-group-1 match of [re] over [text], de-duplicated and sorted. *)
let all_group1 re text =
  let acc = ref [] and pos = ref 0 in
  (try
     while true do
       let _ = Str.search_forward re text !pos in
       acc := Str.matched_group 1 text :: !acc;
       pos := Str.match_end ()
     done
   with Not_found -> ());
  List.sort_uniq compare !acc

(* The slice of [text] between the marker [start] and the first [stop] after it,
   used to confine a search to one grammar rule / list literal. *)
let region ~start ~stop text =
  let i = Str.search_forward (Str.regexp_string start) text 0 in
  let j = Str.search_forward (Str.regexp_string stop) text i in
  String.sub text i (j - i)

let () =
  let lexer, parser_, namespace =
    match Sys.argv with
    | [| _; a; b; c |] -> (a, b, c)
    | _ -> failwith "usage: check_keywords lexer.ml parser.mly namespace.ml"
  in
  (* Bare lowercase keyword arms [| "word" -> TOKEN], excluding the [_] hole. *)
  let keywords =
    all_group1 (Str.regexp {|"\([a-z_]+\)" ->|}) (read_file lexer)
    |> List.filter (fun k -> k <> "_")
  in
  let ident_or_keyword =
    region ~start:"ident_or_keyword:" ~stop:"\n\n" (read_file parser_)
    |> all_group1 (Str.regexp {|{ "\([a-z_]+\)" }|})
  in
  let reserved =
    region ~start:"let reserved =" ~stop:"]" (read_file namespace)
    |> all_group1 (Str.regexp {|"\([a-z_]+\)"|})
  in
  let missing_from name set =
    List.filter (fun k -> not (List.mem k set)) keywords
    |> List.map (fun k -> (k, name))
  in
  let problems =
    missing_from "ident_or_keyword (src/lib-wax/parser.mly)" ident_or_keyword
    @ missing_from "reserved (src/lib-conversion/namespace.ml)" reserved
  in
  match problems with
  | [] -> ()
  | _ ->
      List.iter
        (fun (kw, where) ->
          Printf.eprintf "keyword %S is missing from %s\n" kw where)
        problems;
      exit 1
