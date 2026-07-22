(* 
   Analysis and Error Message Generation for Menhir .messages files.
   
   This tool provides functionality to:
   1. Parse .messages files.
   2. Analyze grammar to understand symbol expansions.
   3. Generate user-friendly error messages using heuristics.
*)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)
module StatusMap = Map.Make (String)

type status = Direct | Lookahead | Both

(* --- Exact Grammar (menhirSdk / .cmly) --- *)

(* The grammar knowledge the continuation computation needs, read from the
   [.cmly] file rather than reconstructed from the LR items that happen to
   appear in error states (the old scrape was provably incomplete: a
   menhir-generated symbol whose defining item was absent from every sampled
   state lost its continuations, and nullability was a name-prefix guess that
   missed opaque nullable nonterminals like [statement_list]). *)
type gram = {
  is_terminal : string -> bool;
  nullable : string -> bool;  (** false for terminals and unknown names *)
  productions : string -> string list list;
      (** each right-hand side as a list of surface symbol names *)
  is_generated : string -> bool;
      (** menhir-generated (a parametric-rule instantiation or an inlined
          anonymous rule) — expand it through its productions; a user-named
          nonterminal stays opaque *)
}

(* The LR(1) automaton, read from the same [.cmly], keyed by the state number
   the [.messages] file carries ([## Ends in an error in state: N]). This is the
   ground truth the soundness oracle checks the generated "Expecting …" claims
   against: a claimed terminal must have a real shift or reduce action in the
   state, a claimed nonterminal a real goto. All accessors take the raw state
   number and are bounds-checked by the caller against [num_states]. *)
type automaton = {
  num_states : int;
  core_items : int -> (string * string list * string list) list;
      (** the state's LR(0) core items as (lhs, symbols-before-dot,
          symbols-after-dot) — used to confirm the [.messages] state numbering
          matches the SDK's [Lr1] numbering *)
  shift_terminals : int -> StringSet.t;
      (** terminals with a shift transition out of the state (error pseudo-token
          excluded) *)
  goto_nonterminals : int -> StringSet.t;
      (** nonterminals with a goto transition out of the state *)
  reduce_terminals : int -> StringSet.t;
      (** lookahead terminals on which the state reduces; a state with a default
          reduction reduces on every terminal, so this is all regular terminals
          there *)
  first_set : string -> StringSet.t;
      (** FIRST(nt) as terminal names (empty for an unknown / terminal name);
          menhir computes it through nullable prefixes already *)
}

(* A menhir-generated nonterminal is a parametric-rule instantiation
   ([option(...)], [list(...)], the [separated_*] / [loption] / [boption]
   wrappers, and the inlined [__anonymous_*] rules) — all of which carry a '(' in
   their surface name — or a bare anonymous symbol. Such a symbol is expanded
   through its productions; a user-named nonterminal ([expression],
   [statement_list], …) is kept opaque, the deliberate design of naming the
   construct rather than its FIRST set. *)
let symbol_is_generated s =
  String.contains s '('
  || (String.length s >= 11 && String.sub s 0 11 = "__anonymous")

(* Menhir stores a token alias with its surrounding quotes ("\"(\"" for "("). *)
let strip_alias_quotes a =
  let n = String.length a in
  if n >= 2 && a.[0] = '"' && a.[n - 1] = '"' then String.sub a 1 (n - 2) else a

(* Read the [.cmly] file and expose the terminal alias table (for readable names
   and the delimiter-depth scan) alongside the structural [gram] the
   continuation computation consumes. *)
let load_grammar cmly_file =
  let module G = MenhirSdk.Cmly_read.Read (struct
    let filename = cmly_file
  end) in
  let open G in
  let terminals = Hashtbl.create 128 in
  List.iter
    (fun (name, tok) ->
      match Surface.Token.alias tok with
      | Some a -> Hashtbl.replace terminals name (strip_alias_quotes a)
      | None -> ())
    (Surface.Syntax.tokens Surface.before_inlining);
  let terminal_names = Hashtbl.create 128 in
  Terminal.iter (fun t -> Hashtbl.replace terminal_names (Terminal.name t) ());
  let nullable_tbl = Hashtbl.create 256 in
  let prod_tbl = Hashtbl.create 256 in
  Nonterminal.iter (fun nt ->
      Hashtbl.replace nullable_tbl (Nonterminal.name nt)
        (Nonterminal.nullable nt);
      Hashtbl.replace prod_tbl (Nonterminal.name nt) []);
  Production.iter (fun p ->
      let lhs = Nonterminal.name (Production.lhs p) in
      let rhs =
        Array.to_list (Production.rhs p)
        |> List.map (fun (s, _, _) -> Symbol.name s)
      in
      let existing = try Hashtbl.find prod_tbl lhs with Not_found -> [] in
      Hashtbl.replace prod_tbl lhs (existing @ [ rhs ]));
  let gram =
    {
      is_terminal = (fun s -> Hashtbl.mem terminal_names s);
      nullable =
        (fun s -> try Hashtbl.find nullable_tbl s with Not_found -> false);
      productions =
        (fun s -> try Hashtbl.find prod_tbl s with Not_found -> []);
      is_generated = symbol_is_generated;
    }
  in
  (* Automaton view (soundness oracle). *)
  let is_error_term t = Terminal.kind t = `ERROR in
  let all_regular_terminals =
    Terminal.fold
      (fun t acc ->
        if is_error_term t then acc else StringSet.add (Terminal.name t) acc)
      StringSet.empty
  in
  let first_tbl = Hashtbl.create 256 in
  Nonterminal.iter (fun nt ->
      Hashtbl.replace first_tbl (Nonterminal.name nt)
        (Nonterminal.first nt |> List.map Terminal.name |> StringSet.of_list));
  let core_items n =
    let st = Lr1.of_int n in
    Lr0.items (Lr1.lr0 st)
    |> List.map (fun (prod, dot) ->
        let lhs = Nonterminal.name (Production.lhs prod) in
        let rhs =
          Production.rhs prod |> Array.to_list
          |> List.map (fun (s, _, _) -> Symbol.name s)
        in
        let before = List.filteri (fun i _ -> i < dot) rhs in
        let after = List.filteri (fun i _ -> i >= dot) rhs in
        (lhs, before, after))
  in
  let shift_terminals n =
    Lr1.transitions (Lr1.of_int n)
    |> List.filter_map (function
      | T t, _ -> if is_error_term t then None else Some (Terminal.name t)
      | N _, _ -> None)
    |> StringSet.of_list
  in
  let goto_nonterminals n =
    Lr1.transitions (Lr1.of_int n)
    |> List.filter_map (function
      | N nt, _ -> Some (Nonterminal.name nt)
      | T _, _ -> None)
    |> StringSet.of_list
  in
  let reduce_terminals n =
    let st = Lr1.of_int n in
    match Lr1.default_reduction st with
    | Some _ -> all_regular_terminals
    | None ->
        Lr1.get_reductions st
        |> List.filter_map (fun (t, _) ->
            if is_error_term t then None else Some (Terminal.name t))
        |> StringSet.of_list
  in
  let auto =
    {
      num_states = Lr1.count;
      core_items;
      shift_terminals;
      goto_nonterminals;
      reduce_terminals;
      first_set =
        (fun name ->
          try Hashtbl.find first_tbl name with Not_found -> StringSet.empty);
    }
  in
  (terminals, gram, auto)

(* Check if a symbol involves an anonymous symbol generated by Menhir *)
let involves_anonymous s =
  let pattern = "__anonymous" in
  let plen = String.length pattern in
  let slen = String.length s in
  let rec check i =
    if i + plen > slen then false
    else if String.sub s i plen = pattern then true
    else check (i + 1)
  in
  check 0

(* The opaque continuation symbols a symbol can begin with: terminals and
   user-named nonterminals. A menhir-generated symbol is expanded through its
   productions (a FIRST-set walk honouring the SDK's real nullability); a
   terminal or a user-named nonterminal is returned as-is. Cycles are cut by
   [visited]. *)
let rec expand_symbol gram visited s =
  if StringSet.mem s visited then StringSet.empty
  else if gram.is_terminal s then StringSet.singleton s
  else
    let visited = StringSet.add s visited in
    if gram.is_generated s then
      List.fold_left
        (fun acc rhs -> StringSet.union acc (first_of_rhs gram visited rhs))
        StringSet.empty (gram.productions s)
    else StringSet.singleton s (* user-named nonterminal: opaque *)

and first_of_rhs gram visited = function
  | [] -> StringSet.empty
  | sym :: rest ->
      let f = expand_symbol gram visited sym in
      if gram.nullable sym then
        StringSet.union f (first_of_rhs gram visited rest)
      else f

(* Helper for StatusMap *)
let add_status s status map =
  let new_status =
    match StatusMap.find_opt s map with
    | None -> status
    | Some old -> if old = status then old else Both
  in
  StatusMap.add s new_status map

let union_status map1 map2 =
  StatusMap.fold (fun s status acc -> add_status s status acc) map2 map1

(* 
   Collect all possible next symbols (continuations) given the RHS after the dot.
   Handles nullability to look past nullable symbols.
*)
let direct_firsts gram symbol =
  StringSet.fold
    (fun s acc -> add_status s Direct acc)
    (expand_symbol gram StringSet.empty symbol)
    StatusMap.empty

(* Continuations given the rhs after the dot. Walk the symbols left to right,
   contributing each one's FIRST set (opaque for a user-named nonterminal,
   expanded for a menhir-generated one); continue past a symbol to the next only
   when it is nullable AND [look_past] admits it; and when the whole remaining
   tail is nullable, fold in the item's reduce-lookaheads (the tokens that may
   follow once every remaining symbol vanishes).

   [look_past] is what distinguishes the two tiers the caller picks between:
   - aggressive ([fun _ -> true]) skips past every nullable symbol, so an opaque
     nullable nonterminal like [statement_list] reveals the tokens legal right
     after it (e.g. '}');
   - conservative ([gram.is_generated]) skips only past menhir-generated nullable
     wrappers (option/list/semi_list/…), keeping a user-named nullable
     nonterminal opaque — the pre-SDK policy, but now with exact expansion.
   Because the aggressive set is a superset of the conservative one, the caller
   can prefer it whenever it still fits the readable cap and fall back to the
   conservative view otherwise, never losing a symbol the old output showed. *)
let rec collect_continuations ~look_past gram rhs_after lookaheads =
  match rhs_after with
  | [] ->
      List.fold_left
        (fun acc s -> add_status s Lookahead acc)
        StatusMap.empty lookaheads
  | symbol :: rest ->
      let base = direct_firsts gram symbol in
      if gram.nullable symbol && look_past symbol then
        union_status base
          (collect_continuations ~look_past gram rest lookaheads)
      else base

(* --- Depth Calculation --- *)

(* The opening delimiter each closer terminates, keyed by the closer's own
   readable spelling: a ')' closes a '(', etc. A terminal is an opener for that
   closer when its token alias begins with this character — so the opener table
   is derived from the grammar's [%token NAME "alias"] declarations rather than
   hand-maintained (the hand-list went stale, missing e.g. the [(@if] / [(on]
   openers). *)
let opener_char_of_closer = function
  | "RBRACE" -> Some '{'
  | "RBRACKET" -> Some '['
  | "RPAREN" -> Some '('
  | _ -> None

let opens_with terminals c token =
  match Hashtbl.find_opt terminals token with
  | Some a -> String.length a > 0 && a.[0] = c
  | None -> false

(*
   Find depth of the matching opener for a given closer.
   Depth is defined as the 1-based index from the top of the stack (right end of the sentence).
   Every token counts as depth 1.
*)
let find_matching_depth terminals sentence closer =
  let tokens =
    String.split_on_char ' ' sentence
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let reversed = List.rev tokens in

  match opener_char_of_closer closer with
  | None -> None
  | Some opener_c ->
      let rec scan depth balance items =
        match items with
        | [] -> None (* Not found *)
        | token :: rest ->
            let current_depth = depth + 1 in
            if token = closer then scan current_depth (balance + 1) rest
            else if opens_with terminals opener_c token then
              if balance > 0 then scan current_depth (balance - 1) rest
              else Some current_depth
            else scan current_depth balance rest
      in
      scan 0 0 reversed

(* --- Message Generation --- *)

let format_human_list items =
  match List.rev items with
  | [] -> ""
  | [ x ] -> x
  | last :: rest -> String.concat ", " (List.rev rest) ^ ", or " ^ last

(* Fixed readable names for symbols whose auto-derived rendering would be
   internal jargon or grammatically wrong; [None] falls through to the
   derivation in [get_readable_name]. *)
let special_name = function
  | "IDENT" -> Some "an identifier"
  | "INT" -> Some "an integer"
  | "FLOAT" -> Some "a float"
  | "STRING" -> Some "a string"
  | "CHAR" -> Some "a character"
  | "EOF" -> Some "end of file"
  | "u8" -> Some "an 8-bit unsigned integer"
  | "u32" -> Some "a 32-bit unsigned integer"
  | "u64" -> Some "a 64-bit unsigned integer"
  | "i8" -> Some "an 8-bit signed integer"
  | "i16" -> Some "a 16-bit signed integer"
  | "i32" -> Some "a 32-bit signed integer"
  | "i64" -> Some "a 64-bit signed integer"
  | "f32" -> Some "a 32-bit float"
  | "f64" -> Some "a 64-bit float"
  | "LPAREN_IMPORT" -> Some "an inline import"
  | "NAT" -> Some "an integer"
  | "MEM_OFFSET" -> Some "a memory offset"
  | "MEM_ALIGN" -> Some "a memory alignment"
  (* Readable names for grammar nonterminals whose auto-derived form is
     internal jargon ("a blockinstr") or grammatically wrong ("a mem limits",
     where the [is_plural] heuristic below misfires). A plural alias carries no
     article, so the "Assuming that the … is/are complete" template picks
     "are"; a singular one keeps its article. *)
  | "blockinstr" | "braced_block" -> Some "a block"
  | "import_kind_decl" -> Some "an import declaration"
  | "on_clauses" -> Some "an on-clause list"
  | "mem_limits" -> Some "memory limits"
  | "mem_pagesize" | "pagesize_clause" -> Some "a page-size clause"
  | "condition_relop" -> Some "a comparison operator"
  | "branch_expr" -> Some "a branch expression"
  | "legacy_catch" -> Some "a catch clause"
  | "legacy_catch_all" -> Some "a catch-all clause"
  (* WAT (lib-wasm) nonterminals whose derived name is an abbreviation or reads
     oddly. *)
  | "result_pat" -> Some "a result pattern"
  | "float_or_nan" -> Some "a float or NaN"
  (* Head noun is "list", not the plural tail: keep the article so the
     "… is complete" template agrees ("the list of indices is", not "are"). *)
  | "list_of_indices" -> Some "a list of indices"
  | _ -> None

(* Collapse the many wax infix-operator continuations into a single readable
   class *before* the <=5 cap, so a state whose FOLLOW is "a closer or any
   operator" (e.g. the [expression] FOLLOW) reads "Expecting ')', or an
   operator." instead of overflowing to the generic fallback. Keyed by wax token
   name; the WAT grammar has none of these tokens, so it is unaffected. The
   compound-assignment variants ([+=] …) are operators too and join the class. *)
let operator_tokens =
  [
    "PLUS";
    "MINUS";
    "STAR";
    "SLASH";
    "SLASHS";
    "SLASHU";
    "PERCENTS";
    "PERCENTU";
    "AMPERSAND";
    "PIPE";
    "CARET";
    "SHL";
    "SHRS";
    "SHRU";
    "PLUSEQUAL";
    "MINUSEQUAL";
    "STAREQUAL";
    "SLASHEQUAL";
    "SLASHSEQUAL";
    "SLASHUEQUAL";
    "PERCENTSEQUAL";
    "PERCENTUEQUAL";
    "AMPERSANDEQUAL";
    "PIPEEQUAL";
    "CARETEQUAL";
    "SHLEQUAL";
    "SHRSEQUAL";
    "SHRUEQUAL";
  ]

let comparison_tokens =
  [
    "EQUALEQUAL";
    "BANGEQUAL";
    "LT";
    "LTS";
    "LTU";
    "LE";
    "LES";
    "LEU";
    "GT";
    "GTS";
    "GTU";
    "GE";
    "GES";
    "GEU";
  ]

let classify_symbol s =
  if List.mem s operator_tokens then Some "an operator"
  else if List.mem s comparison_tokens then Some "a comparison operator"
  else None

let get_readable_name terminals s =
  try Printf.sprintf "'%s'" (Hashtbl.find terminals s)
  with Not_found -> (
    match special_name s with
    | Some name -> name
    | None ->
        if String.lowercase_ascii s = s then
          (* Non-terminals: "some_name" -> "a/an some name" *)
          let parts = String.split_on_char '_' s in
          let parts = List.filter (fun p -> p <> "") parts in
          if parts = [] then s
          else
            let name = String.concat " " parts in
            match parts with
            | p :: _ ->
                let c = String.get p 0 in
                (* Drop the article for a plural noun phrase ("folded
                   instructions", not "a folded instructions"). Plurality is
                   decided by the LAST word — "descriptor clauses" is plural,
                   "expression list" is not — so the article agrees with the
                   head noun. *)
                let last = List.nth parts (List.length parts - 1) in
                let is_plural =
                  String.length last > 1
                  && String.sub last (String.length last - 1) 1 = "s"
                  && not
                       (List.mem last
                          [ "as"; "is"; "this"; "plus"; "minus"; "address" ])
                in
                if is_plural then name
                else if List.mem c [ 'a'; 'e'; 'i'; 'o'; 'u' ] then "an " ^ name
                else "a " ^ name
            | _ -> name
        else
          (* Keywords/Other Terminals: "TOKEN" -> "'token'" *)
          "'" ^ String.lowercase_ascii s ^ "'")

(* --- Self-Lints and Statistics --- *)

type message_stat = {
  expecting : bool;  (** A real "Expecting …" list was emitted. *)
  assuming : bool;  (** The spurious-reduction template was used. *)
  empty_expected : bool;
      (** Generic fallback: no symbols left after filtering. *)
  overflow_expected : bool;  (** Generic fallback: more than 5 symbols. *)
  hinted : bool;  (** A delimiter depth hint was emitted. *)
  missed_hints : string list;
      (** Closers that are valid in this state and have an opener-looking token
          on the known stack suffix, yet [find_matching_depth] found no match —
          the symptom of a stale opener table in [find_matching_depth]. *)
  jargon : StringSet.t;
      (** Terminals emitted in a message through the last-resort
          quoted-lowercase rendering whose name contains '_' (e.g.
          'string_annot') — jargon, not source syntax; needs an alias in the
          grammar or a [special_name] entry. *)
  claims : string list;
      (** The raw symbols a real "Expecting …" list is built from (the
          post-filter, pre-readable-name continuation set), or [] when no such
          list was emitted (generic-fallback states claim nothing). The
          soundness oracle checks each of these against the automaton. *)
}

(* Would [token] plausibly open the construct [closer] terminates? Broader than
   the exact table in [find_matching_depth] on purpose: this is the lint's net
   for openers that table forgot. *)
let opener_like terminals closer token =
  let alias_starts c =
    match Hashtbl.find_opt terminals token with
    | Some a -> String.length a > 0 && a.[0] = c
    | None -> false
  in
  match closer with
  | "RBRACE" -> token = "LBRACE" || alias_starts '{'
  | "RBRACKET" -> token = "LBRACKET" || alias_starts '['
  | "RPAREN" ->
      String.starts_with ~prefix:"LPAREN" token
      || String.ends_with ~suffix:"_ANNOT" token
      || alias_starts '('
  | _ -> false

(* Does the known stack suffix contain an opener-like token with no matching
   closer? Same balance scan as [find_matching_depth], but with the broad
   [opener_like] net as the opener test — so the lint reports a genuinely
   unmatched opener [find_matching_depth]'s (narrower) table missed, not a token
   that merely appears somewhere in a balanced pair (e.g. the matched
   [LPAREN parameter_list RPAREN] suffix, which needs no hint). [sentence] is the
   space-joined known stack suffix — split into tokens as [find_matching_depth]
   does, since the raw stack lines glue several tokens together. *)
let unmatched_opener_like terminals closer sentence =
  let tokens =
    String.split_on_char ' ' sentence
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let reversed = List.rev tokens in
  let rec scan balance = function
    | [] -> false
    | token :: rest ->
        if token = closer then scan (balance + 1) rest
        else if opener_like terminals closer token then
          if balance > 0 then scan (balance - 1) rest else true
        else scan balance rest
  in
  scan 0 reversed

let renders_as_jargon terminals s =
  String.uppercase_ascii s = s
  && (not (Hashtbl.mem terminals s))
  && special_name s = None
  && String.contains s '_'

let generate_message grammar terminals ~comments entry =
  let d = entry.Parse_messages.data in

  (* Heuristic: Formatting Logic *)
  let readable_name = get_readable_name terminals in

  (* The final expected list for a set of valid symbols: drop any anonymous
     residue, then collapse an operator class only when it has >=2 members
     present in this state, so a *large* operator continuation reads "an
     operator" while a lone operator keeps its precise spelling (rendering a
     single valid operator as "an operator" would wrongly suggest others are
     legal). The class then counts as one symbol against the <=5 cap. *)
  let expected_of valid_symbols =
    let expected_raw =
      valid_symbols
      |> List.filter (fun s -> not (involves_anonymous s))
      |> List.sort_uniq String.compare
    in
    let class_counts =
      List.fold_left
        (fun acc s ->
          match classify_symbol s with
          | Some c ->
              StringMap.update c
                (function None -> Some 1 | Some n -> Some (n + 1))
                acc
          | None -> acc)
        StringMap.empty expected_raw
    in
    let expected_symbols =
      expected_raw
      |> List.map (fun s ->
          match classify_symbol s with
          | Some c when StringMap.find c class_counts >= 2 -> c
          | _ -> readable_name s)
      |> List.sort_uniq String.compare
    in
    (expected_raw, expected_symbols)
  in

  (* Calculate Valid Next Symbols, choosing between the two continuation tiers
     (see [collect_continuations]): prefer the aggressive set, which skips past
     every nullable symbol (revealing e.g. '}' after a nullable [statement_list]),
     whenever it still fits the readable <=5 cap; otherwise fall back to the
     conservative set, which keeps a user-named nullable nonterminal opaque
     rather than letting its near-universal FOLLOW overflow into a worse generic
     fallback. The aggressive set is a superset of the conservative one, so the
     fallback never drops a symbol the conservative (old) view would have
     shown. *)
  let symbols_of look_past =
    List.fold_left
      (fun acc item ->
        union_status acc
          (collect_continuations ~look_past grammar
             item.Parse_messages.rhs_after item.Parse_messages.lookaheads))
      StatusMap.empty d.lr1_items
  in
  let vs_agg =
    symbols_of (fun _ -> true) |> StatusMap.bindings |> List.map fst
  in
  let expected_raw_agg, exp_agg = expected_of vs_agg in
  let valid_symbols, expected_raw, expected_symbols =
    let n = List.length exp_agg in
    if n >= 1 && n <= 5 then (vs_agg, expected_raw_agg, exp_agg)
    else
      let vs_c =
        symbols_of grammar.is_generated |> StatusMap.bindings |> List.map fst
      in
      let expected_raw_c, exp_c = expected_of vs_c in
      (vs_c, expected_raw_c, exp_c)
  in

  let sentence =
    if d.stack_suffix <> [] then String.concat " " d.stack_suffix
    else entry.Parse_messages.sentence
  in

  let buf = Buffer.create 256 in

  (* Output: Original Sentence and Comments. The [##] comments carry state
     numbers and LR items, which churn wholesale on any grammar change; the
     [comments:false] mode omits them so the output is a stable
     sentence-to-message projection, suitable as a promoted golden file. *)
  if comments && entry.Parse_messages.original_comments <> [] then
    Printf.bprintf buf "%s: %s\n%s\n\n" entry.Parse_messages.entry_point
      entry.Parse_messages.sentence
      (String.concat "\n" entry.Parse_messages.original_comments)
  else
    Printf.bprintf buf "%s: %s\n\n" entry.Parse_messages.entry_point
      entry.Parse_messages.sentence;

  (* Heuristic: Unclosed Delimiters *)
  let check_unclosed closer opener_str friendly_name =
    if List.mem closer valid_symbols then
      match find_matching_depth terminals sentence closer with
      | Some depth -> Some (depth, opener_str, friendly_name)
      | None -> None
    else None
  in

  let unclosed_details =
    (* A [<N>] hint resolves N as a stack-cell index at runtime, so it is only
       sound when [find_matching_depth] scanned the *known stack suffix*. With no
       stack suffix the depth would index the raw sentence's tokens, not stack
       cells, and the runtime anchor would be wrong — so emit no hint. *)
    if d.stack_suffix = [] then None
    else
      (* Several closers can be valid in one state; hint at the *innermost* open
         construct — the one whose opener sits nearest the top of the stack
         (smallest depth) — since that is the construct the error is directly
         inside. A stable sort keeps the brace/bracket/paren tie-break order. *)
      [
        check_unclosed "RBRACE" "{" "brace";
        check_unclosed "RBRACKET" "[" "bracket";
        check_unclosed "RPAREN" "(" "parenthesis";
      ]
      |> List.filter_map Fun.id
      |> List.stable_sort (fun (d1, _, _) (d2, _, _) -> compare d1 d2)
      |> function
      | [] -> None
      | x :: _ -> Some x
  in

  (* Construct Error Message *)
  let base_message =
    if List.length expected_symbols > 0 && List.length expected_symbols <= 5
    then Printf.sprintf "Expecting %s." (format_human_list expected_symbols)
    else "Syntax error"
  in

  let message_body =
    match List.rev d.spurious_reductions with
    | [] -> base_message
    | last :: _ ->
        let raw_name = readable_name last.symbol in
        let name, verb =
          if String.length raw_name > 2 && String.sub raw_name 0 2 = "a " then
            (String.sub raw_name 2 (String.length raw_name - 2), "is")
          else if String.length raw_name > 3 && String.sub raw_name 0 3 = "an "
          then (String.sub raw_name 3 (String.length raw_name - 3), "is")
          else if String.length raw_name > 0 && String.get raw_name 0 = '\''
          then (raw_name, "is")
          else (raw_name, "are")
        in
        Printf.sprintf "Assuming that the %s %s complete, %s" name verb
          (if base_message = "Syntax error" then "syntax error."
           else String.uncapitalize_ascii base_message)
  in

  (* Append Hint if an unclosed delimiter was detected on the stack context *)
  let full_message =
    match unclosed_details with
    | Some (depth, opener, _) ->
        (* Locate the opener of the construct the error sits inside, without
           claiming it is unmatched: the same error state is reached both when
           the construct is genuinely unclosed (an EOF cut it short) and when a
           later token inside an already-closed construct is invalid, so a
           "might be unmatched" reading would be false in the latter, common
           case. A purely locational hint is true in both. *)
        message_body ^ "\n"
        ^ Printf.sprintf "<%d>This '%s' opens the enclosing construct." depth
            opener
    | None -> message_body
  in

  Printf.bprintf buf "%s\n\n" full_message;

  (* Self-lints, reported by the [-stats] mode. *)
  let n_expected = List.length expected_symbols in
  let emitted = n_expected > 0 && n_expected <= 5 in
  let missed_hints =
    List.filter
      (fun closer ->
        List.mem closer valid_symbols
        && find_matching_depth terminals sentence closer = None
        && unmatched_opener_like terminals closer
             (String.concat " " d.stack_suffix))
      [ "RBRACE"; "RBRACKET"; "RPAREN" ]
  in
  let jargon =
    if emitted then
      List.fold_left
        (fun acc s ->
          if renders_as_jargon terminals s then StringSet.add s acc else acc)
        StringSet.empty expected_raw
    else StringSet.empty
  in
  let stat =
    {
      expecting = emitted;
      assuming = d.spurious_reductions <> [];
      empty_expected = n_expected = 0;
      overflow_expected = n_expected > 5;
      hinted = unclosed_details <> None;
      missed_hints;
      jargon;
      claims = (if emitted then expected_raw else []);
    }
  in
  (Buffer.contents buf, stat)

(* Analysis: List all possible continuations for states, indicating spurious reductions. *)
let analyze_transitions grammar terminals entries =
  let seen_states = Hashtbl.create 100 in

  Printf.printf "Transitions per state:\n";

  let process_entry entry =
    let d = entry.Parse_messages.data in
    if not (Hashtbl.mem seen_states d.state) then (
      Hashtbl.add seen_states d.state ();

      let all_next =
        List.fold_left
          (fun acc item ->
            let next_map =
              collect_continuations
                ~look_past:(fun _ -> true)
                grammar item.Parse_messages.rhs_after
                item.Parse_messages.lookaheads
            in
            union_status acc next_map)
          StatusMap.empty d.lr1_items
      in

      let symbols = StatusMap.bindings all_next in
      (match List.rev d.spurious_reductions with
      | [] -> Printf.printf "State %d:\n" d.state
      | last :: _ ->
          Printf.printf "State %d (spurious reduction: %s):\n" d.state
            last.symbol);

      let sentence =
        if d.stack_suffix <> [] then String.concat " " d.stack_suffix
        else entry.Parse_messages.sentence
      in

      List.iter
        (fun (s, status) ->
          let note =
            match status with
            | Direct -> ""
            | Lookahead -> " [lookahead]"
            | Both -> " [lookahead]"
          in

          let warning =
            match s with
            | "RBRACE" | "RBRACKET" | "RPAREN" -> (
                match find_matching_depth terminals sentence s with
                | Some depth -> Printf.sprintf " [depth: %d]" depth
                | None -> " [mismatch?]")
            | _ -> ""
          in

          Printf.printf "  %s%s%s\n" s note warning)
        symbols)
  in

  List.iter process_entry entries

(* --- Soundness oracle (state 3) --- *)

(* Does the [.messages] state numbering coincide with the SDK's [Lr1] numbering?
   The [.cmly] and the [--list-errors] sentences come from two menhir
   invocations with different flags, so the correspondence is verified, not
   assumed: for every entry, compare the state's LR(0) core item set as the SDK
   reports it (keyed by [entry.data.state]) against the core items the
   [.messages] comment block lists. Returns (matched, total); [matched = total]
   is the "numbering matches" verdict that lets the oracle key by state number. *)
let check_correspondence auto entries =
  let normalize items =
    items
    |> List.map (fun it ->
        ( it.Parse_messages.lhs,
          it.Parse_messages.rhs_before,
          it.Parse_messages.rhs_after ))
    |> List.sort_uniq compare
  in
  List.fold_left
    (fun (matched, total) entry ->
      let d = entry.Parse_messages.data in
      let sdk_items =
        if d.state >= 0 && d.state < auto.num_states then
          auto.core_items d.state
          |> List.map (fun (lhs, before, after) -> (lhs, before, after))
          |> List.sort_uniq compare
        else []
      in
      let msg_items = normalize d.lr1_items in
      ((if sdk_items = msg_items then matched + 1 else matched), total + 1))
    (0, 0) entries

(* Check one entry's claims against the automaton state it names. Returns the
   unsound claims (a claimed symbol with no matching action/goto) and the
   uncovered actions (terminals the state acts on that no claim covers). Only
   entries that emitted a real "Expecting …" list carry claims; the rest return
   empty. *)
let check_entry gram auto (entry, stat) =
  match stat.claims with
  | [] -> ([], StringSet.empty)
  | claims ->
      let n = entry.Parse_messages.data.state in
      if n < 0 || n >= auto.num_states then (claims, StringSet.empty)
      else
        let action_terms =
          StringSet.union (auto.shift_terminals n) (auto.reduce_terminals n)
        in
        let gotos = auto.goto_nonterminals n in
        (* Soundness: a terminal must have a shift or reduce action. A
           nonterminal M must be one the state can begin parsing. The direct
           case is a goto on M (M sits immediately after the dot). But the
           continuation walk legitimately looks *past* a nullable prefix (step
           2), so M can also be a claim while the dot is still before a nullable
           symbol B (item [X -> α . B M …], B nullable): the goto on M then lives
           in the successor state, not here. That claim is still sound — exactly
           as a terminal revealed past a nullable prefix is reached by reducing
           the empty B and shifting, so is every token of FIRST(M) here. So the
           automaton test for a look-past nonterminal is FIRST(M) ⊆ action set
           (the nonterminal mirror of the terminal reduce-chain the oracle must
           account for), with the goto disjunct covering a pathological
           nullable-only M whose FIRST is empty. *)
        let unsound =
          List.filter
            (fun sym ->
              if gram.is_terminal sym then not (StringSet.mem sym action_terms)
              else
                let first = auto.first_set sym in
                not
                  (StringSet.mem sym gotos
                  || (not (StringSet.is_empty first))
                     && StringSet.subset first action_terms))
            claims
        in
        (* Coverage: a terminal claim covers itself; a nonterminal claim covers
           FIRST(nt). Action terminals no claim covers are uncovered. *)
        let covered =
          List.fold_left
            (fun acc sym ->
              if gram.is_terminal sym then StringSet.add sym acc
              else StringSet.union acc (auto.first_set sym))
            StringSet.empty claims
        in
        (unsound, StringSet.diff action_terms covered)

(* Aggregate the per-entry self-lints into the quality summary pinned by the
   promoted [parser_messages.stats.expected] goldens: regressions (a new
   fallback state, a lost hint, a jargon token) fail `dune runtest`;
   improvements are accepted with `dune promote`. *)
let output_stats gram auto results =
  let count f = List.length (List.filter (fun (_, s) -> f s) results) in
  Printf.printf "entries: %d\n" (List.length results);
  Printf.printf "with an expected list: %d\n" (count (fun s -> s.expecting));
  Printf.printf "using the spurious-reduction template: %d\n"
    (count (fun s -> s.assuming));
  Printf.printf "generic fallback (empty expected list): %d\n"
    (count (fun s -> s.empty_expected));
  Printf.printf "generic fallback (expected list over 5): %d\n"
    (count (fun s -> s.overflow_expected));
  Printf.printf "delimiter hints: %d\n" (count (fun s -> s.hinted));
  let missed =
    List.concat_map
      (fun (entry, s) ->
        List.map (fun closer -> (closer, entry)) s.missed_hints)
      results
  in
  Printf.printf "missed delimiter hints (opener on stack, none matched): %d\n"
    (List.length missed);
  List.iter
    (fun (closer, entry) ->
      Printf.printf "  %s %s: %s\n" closer entry.Parse_messages.entry_point
        entry.Parse_messages.sentence)
    missed;
  let jargon =
    List.fold_left
      (fun acc (_, s) -> StringSet.union acc s.jargon)
      StringSet.empty results
  in
  Printf.printf "jargon-rendered tokens: %d\n" (StringSet.cardinal jargon);
  StringSet.iter (fun s -> Printf.printf "  %s\n" s) jargon;

  (* Soundness oracle (state 3): claims-vs-automaton. *)
  let matched, total = check_correspondence auto (List.map fst results) in
  Printf.printf "state/automaton item-set match: %d/%d\n" matched total;
  let oracle = List.map (fun r -> (r, check_entry gram auto r)) results in
  let unsound_claims =
    List.concat_map
      (fun ((entry, _), (unsound, _)) ->
        List.map (fun sym -> (sym, entry)) unsound)
      oracle
  in
  Printf.printf "unsound claims: %d\n" (List.length unsound_claims);
  List.iter
    (fun (sym, entry) ->
      Printf.printf "  %s %s: %s\n" sym entry.Parse_messages.entry_point
        entry.Parse_messages.sentence)
    unsound_claims;
  let with_uncovered =
    List.filter (fun (_, (_, unc)) -> not (StringSet.is_empty unc)) oracle
  in
  let total_uncovered =
    List.fold_left
      (fun acc (_, (_, unc)) -> acc + StringSet.cardinal unc)
      0 oracle
  in
  Printf.printf "entries with uncovered actions: %d\n"
    (List.length with_uncovered);
  Printf.printf "uncovered action tokens (total): %d\n" total_uncovered;
  if List.length with_uncovered < 15 then
    List.iter
      (fun ((entry, _), (_, unc)) ->
        Printf.printf "  %s %s: %s\n" entry.Parse_messages.entry_point
          entry.Parse_messages.sentence
          (String.concat " " (StringSet.elements unc)))
      with_uncovered

(* --- Main Entry Point --- *)

let main () =
  let input_file = ref "" in
  let generate_messages = ref false in
  let no_comments = ref false in
  let stats = ref false in
  let list_transitions = ref false in
  let cmly_file = ref "" in

  let spec =
    [
      ( "-generate-messages",
        Arg.Set generate_messages,
        "Generate error messages for states" );
      ( "-no-comments",
        Arg.Set no_comments,
        "Omit the auto-generated ## comments (state numbers, LR items) from \
         the output, keeping only the sentence and message" );
      ( "-stats",
        Arg.Set stats,
        "Print the message-quality summary (fallback/hint counts, self-lints) \
         instead of the messages" );
      ( "-list-transitions",
        Arg.Set list_transitions,
        "List all possible continuations for states" );
      ( "-cmly",
        Arg.Set_string cmly_file,
        "Path to the grammar's .cmly file (menhirSdk); the source of exact \
         productions, nullability, and token aliases (required for \
         -generate-messages, -stats, and -list-transitions)" );
    ]
  in

  let usage_msg = "Usage: main.exe [options] <filename.messages>" in

  Arg.parse spec (fun f -> input_file := f) usage_msg;

  if !input_file = "" then (
    Arg.usage spec usage_msg;
    exit 1);

  if !generate_messages && !list_transitions then (
    Printf.eprintf
      "Error: -generate-messages and -list-transitions are mutually exclusive.\n";
    exit 1);

  let entries = Parse_messages.parse_file !input_file in
  Printf.eprintf "Parsed %d entries from %s\n" (List.length entries) !input_file;

  if !generate_messages || !stats || !list_transitions then (
    if !cmly_file = "" then (
      Printf.eprintf "Error: -cmly is required for this mode.\n";
      exit 1);
    let terminals, grammar, auto = load_grammar !cmly_file in
    if !generate_messages || !stats then (
      if !generate_messages then Printf.eprintf "Generating messages...\n";
      let results =
        List.map
          (fun entry ->
            let text, stat =
              generate_message grammar terminals ~comments:(not !no_comments)
                entry
            in
            (entry, (text, stat)))
          entries
      in
      if !generate_messages then
        List.iter (fun (_, (text, _)) -> print_string text) results;
      if !stats then
        output_stats grammar auto
          (List.map (fun (entry, (_, stat)) -> (entry, stat)) results))
    else analyze_transitions grammar terminals entries)
  else if
    (* Default verification dump *)
    entries <> []
  then (
    let first = List.hd entries in
    Printf.printf "First Entry State: %d\n" first.data.state;
    Printf.printf "First Entry Info: %d items\n"
      (List.length first.data.lr1_items))

let () = main ()
