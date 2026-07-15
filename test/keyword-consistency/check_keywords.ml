(* A bare-word keyword of the Wax lexer must be registered in several places,
   most of which fail silently when forgotten:

   - [src/lib-wax/lexer.ml]        the keyword itself (source of truth)
   - [src/lib-wax/parser.mly]      [ident_or_keyword], so it still works as a label
   - [src/lib-conversion/namespace.ml] [reserved], so [from_wasm] renames a
                                    generated entity that would collide with it
   - [editors/vscode/syntaxes/wax.tmLanguage.json] a keyword-highlighting rule,
                                    so the editor grammar colours it
   - [tree-sitter-wax/grammar.js]  the [KEYWORDS] list, so a keyword still works
                                    as a label name in the tree-sitter grammar

   This test extracts the keyword set from the lexer and checks each one appears
   in the other lists, so adding a keyword without updating them fails the build
   with the exact culprit named. It relies on the Wax lexer having no
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
  let lexer, parser_, namespace, grammar, ts_grammar =
    match Sys.argv with
    | [| _; a; b; c; d; e |] -> (a, b, c, d, e)
    | _ ->
        failwith
          "usage: check_keywords lexer.ml parser.mly namespace.ml \
           tmLanguage.json grammar.js"
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
  (* The words listed in the grammar's keyword-highlighting rules, which have the
     shape ["match": "\\b(word|word|...)\\b"]. *)
  let grammar_words =
    all_group1 (Str.regexp {|\\\\b(\([a-z_|]+\))|}) (read_file grammar)
    |> List.concat_map (String.split_on_char '|')
    |> List.sort_uniq compare
  in
  (* The single-quoted words in the tree-sitter grammar's [const KEYWORDS = [ … ]]
     list. Like [ident_or_keyword], this is exactly the bare-word keyword set (it
     is what a [label] name may be), so it is checked both ways. *)
  let ts_keywords =
    region ~start:"const KEYWORDS = [" ~stop:"];" (read_file ts_grammar)
    |> all_group1 (Str.regexp {|'\([a-z_]+\)'|})
  in
  (* A keyword the lexer defines but a list forgets (adding a keyword without
     registering it). *)
  let missing_from name set =
    List.filter (fun k -> not (List.mem k set)) keywords
    |> List.map (fun k -> Printf.sprintf "keyword %S is missing from %s" k name)
  in
  (* A list entry that is no longer a lexer keyword (removing a keyword without
     cleaning up). Only checked for the lists that hold exactly the keyword set;
     the grammar also highlights non-keyword words (attribute names, …), so it
     is checked one way only. *)
  let stale_in name set =
    List.filter (fun k -> not (List.mem k keywords)) set
    |> List.map (fun k ->
        Printf.sprintf "%S in %s is not a lexer keyword" k name)
  in
  let ident_or_keyword_name = "ident_or_keyword (src/lib-wax/parser.mly)" in
  let reserved_name = "reserved (src/lib-conversion/namespace.ml)" in
  let ts_keywords_name = "KEYWORDS (tree-sitter-wax/grammar.js)" in
  let problems =
    missing_from ident_or_keyword_name ident_or_keyword
    @ missing_from reserved_name reserved
    @ missing_from
        "keyword highlighting (editors/vscode/syntaxes/wax.tmLanguage.json)"
        grammar_words
    @ missing_from ts_keywords_name ts_keywords
    @ stale_in ident_or_keyword_name ident_or_keyword
    @ stale_in reserved_name reserved
    @ stale_in ts_keywords_name ts_keywords
  in
  match problems with
  | [] -> ()
  | _ ->
      List.iter (fun m -> Printf.eprintf "%s\n" m) problems;
      exit 1
