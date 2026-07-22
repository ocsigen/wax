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

(* --- List-element chase (step 3b: singular Expecting wording) --- *)

(* Is [nt] a genuinely *list-shaped* nonterminal — one whose "Expecting …"
   rendering should name a single element rather than the list? Two shapes
   qualify: it is directly recursive through itself (right/left-recursive list
   like [instructions], [exports], [catches]), or a production of it mentions a
   stdlib list wrapper ([list(…)] / [nonempty_list(…)] / [separated_…] /
   [loption(separated_…)] / [semi_list(…)], which after menhir's [%inline]
   expansion surface as generated symbol names carrying "list(" or "separated_").
   The guard deliberately excludes a *role-refinement* nonterminal like
   [condition_expression] (whose sole production is [expression]) — there the
   role word is information and must be kept. A false positive is harmless: the
   chase below still only renames when a single common element symbol exists. *)
let is_list_shaped gram nt =
  let is_list_wrapper s =
    let contains sub =
      let ls = String.length s and lsub = String.length sub in
      let rec go i =
        i + lsub <= ls && (String.sub s i lsub = sub || go (i + 1))
      in
      go 0
    in
    gram.is_generated s && (contains "list(" || contains "separated_")
  in
  let prods = gram.productions nt in
  (* Directly recursive through itself ([instructions], [exports], [results],
     [catches], …). *)
  List.exists (List.exists (fun s -> s = nt)) prods
  (* Or a production that *is* a single stdlib list wrapper — the definition of
     an alias like [string_list : list(STRING)] or [expression_list :
     separated_list_trailing(",", expression)] (after [%inline], one
     [loption(separated_…)] symbol). A wrapper that is merely one *field* of a
     larger construct ([action] holds a [const*], [result_pat] a [float_or_nan+])
     does not make the construct a list, so the whole-RHS test excludes it. *)
  || List.exists (function [ s ] -> is_list_wrapper s | _ -> false) prods

(* The single opaque symbol every non-empty production of a list-shaped [nt]
   begins with — the list *element*'s leftmost mandatory symbol. Chasing looks
   through nullable prefixes and menhir-generated wrappers (like [expand_symbol]),
   and treats a recursion back into [nt] as transparent (skipping it: the next
   iteration's leftmost is what starts a *new* element). Returns [Some sym] when
   all non-empty productions agree on one symbol, else [None] (e.g. [instructions]
   has five distinct element openers, [element_list] two — those keep the list
   name). [sym] may be a terminal (rendered via its alias) or another
   nonterminal (rendered recursively, itself possibly list-shaped). *)
let chase_list_element gram nt =
  let rec leftmost_of_symbol visited s =
    if StringSet.mem s visited then StringSet.empty
    else if gram.is_terminal s then StringSet.singleton s
    else if gram.is_generated s then
      let visited = StringSet.add s visited in
      List.fold_left
        (fun acc rhs -> StringSet.union acc (leftmost_of_rhs visited rhs))
        StringSet.empty (gram.productions s)
    else StringSet.singleton s (* user-named nonterminal: opaque element *)
  and leftmost_of_rhs visited = function
    | [] -> StringSet.empty
    | sym :: rest ->
        (* A recursion into the list itself is skipped (transparent), so a
           left-recursive [L -> L x] chases to [x]; a nullable symbol is looked
           past as in the FIRST walk. *)
        if sym = nt then leftmost_of_rhs visited rest
        else
          let f = leftmost_of_symbol visited sym in
          if gram.nullable sym then
            StringSet.union f (leftmost_of_rhs visited rest)
          else f
  in
  let leftmosts =
    List.fold_left
      (fun acc rhs ->
        match rhs with
        | [] -> acc (* skip the empty production of a nullable list *)
        | _ ->
            StringSet.union acc (leftmost_of_rhs (StringSet.singleton nt) rhs))
      StringSet.empty (gram.productions nt)
  in
  match StringSet.elements leftmosts with [ x ] -> Some x | _ -> None

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
  (* List *elements* the step-3b Expecting-position chase lands on, whose
     auto-derived name is an abbreviation ("a local decl", "a param group", "a
     block param type"). Curated here so the singular reads well; the chase only
     reaches them from a list-shaped parent ([locals], [parameters],
     [parameter_types]), so no other message is affected. *)
  | "local_decl" -> Some "a local declaration"
  | "param_group" -> Some "a parameter group"
  | "block_param_type" -> Some "a parameter type"
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

(* Rendering for the *Expecting* position (step 3b). What the user types next is
   one element, so a list-shaped nonterminal is rendered as its singular element
   ("Expecting ')', or an instruction.") rather than the list ("… or
   instructions."). For a user-named, list-shaped nonterminal the chase names the
   common element symbol and renders *that* recursively (a terminal by its alias,
   another nonterminal by its own reading — itself possibly list-shaped); every
   other symbol, and the *Assuming* subject, keep [get_readable_name]. The chase
   overrides a curated [special_name] for a list-shaped name when it fires
   (e.g. [list_of_indices] → "an index", [on_clauses] → the [on]/[[] opener),
   which is intentional; the curated forms remain in force for the Assuming
   subject, which names the whole completed sequence. *)
let rec expecting_name ?(visited = StringSet.empty) terminals gram s =
  if
    (not (Hashtbl.mem terminals s))
    && String.lowercase_ascii s = s
    && (not (gram.is_terminal s))
    && (not (gram.is_generated s))
    && (not (StringSet.mem s visited))
    && is_list_shaped gram s
  then
    match chase_list_element gram s with
    | Some elem ->
        expecting_name ~visited:(StringSet.add s visited) terminals gram elem
    | None -> get_readable_name terminals s
  else get_readable_name terminals s

(* Drop a leading indefinite article from a readable noun phrase
   ("a field type" -> "field type", "an elemexpr" -> "elemexpr"); a quoted
   terminal or an already-article-less phrase is returned unchanged. *)
let strip_article name =
  if String.length name > 2 && String.sub name 0 2 = "a " then
    String.sub name 2 (String.length name - 2)
  else if String.length name > 3 && String.sub name 0 3 = "an " then
    String.sub name 3 (String.length name - 3)
  else name

(* Pluralise the head (last word) of a readable noun phrase, so a *list*
   subject reads "the value types are complete" rather than the singular. The
   rule covers the element names both grammars actually produce (…es after a
   sibilant so "catch" -> "catches"); a phrase whose head is already the wrong
   shape can be curated in [special_name]. *)
let pluralize_phrase name =
  match List.rev (String.split_on_char ' ' name) with
  | [] | [ "" ] -> name
  | last :: rest ->
      let n = String.length last in
      let ends suf =
        let ls = String.length suf in
        n >= ls && String.sub last (n - ls) ls = suf
      in
      let plural =
        if ends "s" || ends "x" || ends "z" || ends "ch" || ends "sh" then
          last ^ "es"
        else last ^ "s"
      in
      String.concat " " (List.rev (plural :: rest))

(* Rendering for the *Assuming that the X is complete* subject. A user-named
   nonterminal names the completed construct directly ("the block type is
   complete"). A menhir-generated symbol — always a list wrapper when it reaches
   [%on_error_reduce], since that is the only reason to annotate one — would
   otherwise render as its raw internal name ("the list(field type) is
   complete", jargon); instead chase its element and pluralise it ("the field
   types are complete"). The [%on_error_reduce] reductions that reach here are
   frequently *epsilon* (an empty list assumed complete), so this subject is what
   signals to the reader that an optional list element was elided from the
   Expecting list rather than being illegal — the hedge whose absence silently
   dropped tokens. *)
let subject_name terminals gram s =
  if gram.is_generated s then
    match chase_list_element gram s with
    | Some elem ->
        pluralize_phrase (strip_article (expecting_name terminals gram elem))
    | None -> "a list"
  else get_readable_name terminals s

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
  overridden : bool;
      (** The message was replaced by a hand-written entry from the per-grammar
          [.overrides] file (step 5). An overridden entry is excluded from the
          fallback counters (it is no longer a generic fallback) and from the
          soundness/jargon self-lints, which cannot parse free prose — see the
          override-merge site in [generate_message] for the claim-soundness
          responsibility note. *)
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

(* --- Hand-written overrides (step 5, the sanctioned escape hatch) --- *)

(* A per-grammar [.overrides] file supplies hand-written messages for the states
   heuristics cannot serve — chiefly the structurally immovable over-5
   "enumeration" fallbacks (the dot at the start of a construct whose FIRST set
   overflows the readable cap, so the generated message degrades to a bare
   "Syntax error"). It is keyed by the *sentence* (`entry_point: sentence`, the
   stable key — state numbers renumber on any grammar change, sentences do not)
   and merged after generation. The file mirrors the [.messages] shape: blocks
   separated by blank lines; within a block, lines beginning with '#' (after
   optional leading whitespace) are rationale comments, the first surviving line
   is the `entry_point: sentence` header, and the remaining lines are the
   replacement message body (a single line, or a message plus a [<N>] delimiter-
   hint line). *)
let load_overrides file =
  let lines = Parse_messages.read_lines file in
  let blocks =
    (* Same blank-line block split as the [.messages] parser. *)
    let rec aux cur acc = function
      | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
      | line :: rest ->
          if String.trim line = "" then
            if cur = [] then aux [] acc rest
            else aux [] (List.rev cur :: acc) rest
          else aux (line :: cur) acc rest
    in
    aux [] [] lines
  in
  List.fold_left
    (fun map block ->
      let is_comment l =
        let t = String.trim l in
        String.length t > 0 && t.[0] = '#'
      in
      match List.filter (fun l -> not (is_comment l)) block with
      | [] -> map
      | header :: body ->
          let header = String.trim header in
          if String.length header = 0 then map
          else StringMap.add header (String.concat "\n" body) map)
    StringMap.empty blocks

(* Validate any [<N>] depth marker an override carries the same way a generated
   hint is bounded: [N] is a 1-based stack-cell index the runtime resolves with
   [MenhirInterpreter.get (N-1)], so it must fall within the state's known stack
   suffix (a marker past the suffix would point the underline at the wrong cell
   — or off the stack). A bad marker is a hard build error. Claim-soundness of
   the *prose* itself (that the listed continuations are the ones the state
   actually accepts) is the override author's responsibility — the oracle checks
   symbols, not sentences, so it cannot vet free text. *)
let validate_override_depths ~header body stack_suffix =
  let n_cells =
    String.concat " " stack_suffix
    |> String.split_on_char ' '
    |> List.filter (fun s -> String.trim s <> "")
    |> List.length
  in
  let re = Str.regexp "<\\([0-9]+\\)>" in
  let rec scan pos =
    match Str.search_forward re body pos with
    | exception Not_found -> ()
    | i ->
        let n = int_of_string (Str.matched_group 1 body) in
        if n < 1 || n > n_cells then
          failwith
            (Printf.sprintf
               "override for %S: depth marker <%d> is out of range (stack \
                suffix has %d cells)"
               header n n_cells);
        scan (i + String.length (Str.matched_string body))
  in
  scan 0

(* Report an override whose sentence matches no generated entry: the file must
   never drift silently, so a stale key fails the build. Called once the full
   entry set is known. *)
let check_override_rot overrides entries =
  let headers =
    List.fold_left
      (fun acc e ->
        StringSet.add
          (e.Parse_messages.entry_point ^ ": " ^ e.Parse_messages.sentence)
          acc)
      StringSet.empty entries
  in
  StringMap.iter
    (fun key _ ->
      if not (StringSet.mem key headers) then
        failwith
          (Printf.sprintf
             "override for %S matches no error state (stale entry — remove or \
              fix it)"
             key))
    overrides

let generate_message grammar terminals ~comments ~overrides entry =
  let d = entry.Parse_messages.data in

  (* Heuristic: Formatting Logic. [subject_name] renders the Assuming subject
     (the whole completed construct — a user-named nonterminal by name, a
     generated list wrapper by its pluralised element); [expecting_name] renders
     the Expecting list (one element — singularises a list-shaped name). *)
  let subject_name = subject_name terminals grammar in
  let expecting_name = expecting_name terminals grammar in

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
          | _ -> expecting_name s)
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

  (* The "Assuming that the X is complete" subject is the *outermost* spurious
     reduction (the last in menhir's innermost→outermost list). A/B'd against the
     innermost in step 4b: outermost wins because the Expecting token is the
     FOLLOW of the outermost frame, so naming that frame keeps hedge and
     expectation coherent ("the instructions are complete, expecting 'end'"),
     whereas the innermost names the construct at the edit point but pairs it with
     a FOLLOW token from a wider frame ("the parameters without bindings are
     complete, expecting 'end'" — incoherent, and jargon). Outermost also keeps
     the step-4 "block type is complete" messages and avoids the raw-grammar
     "plaininstr"/"parameters without bindings" subjects the innermost surfaced on
     the deep cascades. *)
  let message_body =
    match List.rev d.spurious_reductions with
    | [] -> base_message
    | last :: _ ->
        let raw_name = subject_name last.symbol in
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
  let generated_message =
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

  (* Hand-override merge (step 5): if the sanctioned [.overrides] file supplies a
     message for this state's sentence, it replaces the generated one verbatim.
     The override text is the author's own prose — its claim-soundness is NOT
     machine-checked (the oracle keys on raw symbols, not sentences), only its
     [<N>] depth markers are bounds-checked; see [validate_override_depths]. An
     overridden entry drops out of the fallback counters and the self-lints
     below. *)
  let header =
    entry.Parse_messages.entry_point ^ ": " ^ entry.Parse_messages.sentence
  in
  let overridden, full_message =
    match StringMap.find_opt header overrides with
    | Some body ->
        validate_override_depths ~header body d.stack_suffix;
        (true, body)
    | None -> (false, generated_message)
  in

  Printf.bprintf buf "%s\n\n" full_message;

  (* Self-lints, reported by the [-stats] mode. An overridden entry is exempt:
     it is neither a generated "Expecting …" nor a generic fallback, so it
     carries no claims (nothing for the soundness/jargon oracle to check) and no
     computed hint (its hint, if any, is author-written and counted straight
     from the override text). *)
  let n_expected = List.length expected_symbols in
  let emitted = (not overridden) && n_expected > 0 && n_expected <= 5 in
  let missed_hints =
    if overridden then []
    else
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
      assuming = (not overridden) && d.spurious_reductions <> [];
      empty_expected = (not overridden) && n_expected = 0;
      overflow_expected = (not overridden) && n_expected > 5;
      hinted =
        (if overridden then String.contains full_message '<'
         else unclosed_details <> None);
      missed_hints;
      jargon;
      claims = (if emitted then expected_raw else []);
      overridden;
    }
  in
  (* [full_message] is returned separately for the census (step 7), which counts
     distinct message bodies without the per-entry sentence header. *)
  (Buffer.contents buf, full_message, stat)

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
  (* Cascade depth = the number of spurious reductions folded before the error
     is reported (the length of the "Assuming …" chain). A deep cascade means
     the hedge names a construct far from where the user was editing; the prune
     audit (step 4b) watches these so over-annotation is measurable. *)
  let cascade_depths =
    List.map
      (fun (entry, _) ->
        List.length entry.Parse_messages.data.spurious_reductions)
      results
  in
  Printf.printf "entries with cascade depth >= 4: %d\n"
    (List.length (List.filter (fun d -> d >= 4) cascade_depths));
  Printf.printf "max cascade depth: %d\n" (List.fold_left max 0 cascade_depths);
  (* Hand-written overrides (step 5). The fallback counters below exclude these
     (their [overflow_expected]/[empty_expected] are forced false), so
     "not overridden" is the new ratchet target: a genuinely un-overridable
     enumeration state that still degrades to "Syntax error". *)
  Printf.printf "overridden: %d\n" (count (fun s -> s.overridden));
  Printf.printf "generic fallback (empty expected list, not overridden): %d\n"
    (count (fun s -> s.empty_expected));
  Printf.printf "generic fallback (expected list over 5, not overridden): %d\n"
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

(* --- Message census (step 7) --- *)

(* Normalize a message body for the census: collapse the state-specific depth in
   a delimiter hint ([<3>This '(' …] -> [<_>…]) so identical wordings at
   different stack depths count as one census line and a depth shift does not
   churn the counts. Kept verbatim, that depth would fragment one wording into
   several census entries. *)
let census_normalize body =
  Str.global_replace (Str.regexp "<[0-9]+>") "<_>" body

(* Emit the message census: each distinct (depth-normalized) message body once,
   prefixed by its occurrence count, sorted by the message text. Entry sentences
   never appear, so sentence re-picking at most bumps a count and a wording
   change is a one-line diff. A multi-line body (hedge + delimiter hint) is one
   census item; its continuation lines are indented to the message column. *)
let output_census bodies =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun body ->
      let key = census_normalize body in
      let n = try Hashtbl.find tbl key with Not_found -> 0 in
      Hashtbl.replace tbl key (n + 1))
    bodies;
  Hashtbl.fold (fun msg count acc -> (msg, count) :: acc) tbl []
  |> List.sort (fun (m1, _) (m2, _) -> String.compare m1 m2)
  |> List.iter (fun (msg, count) ->
      match String.split_on_char '\n' msg with
      | [] -> ()
      | first :: rest ->
          Printf.printf "%5dx %s\n" count first;
          List.iter (fun l -> Printf.printf "       %s\n" l) rest)

(* --- Main Entry Point --- *)

let main () =
  let input_file = ref "" in
  let generate_messages = ref false in
  let no_comments = ref false in
  let census = ref false in
  let stats = ref false in
  let list_transitions = ref false in
  let cmly_file = ref "" in
  let overrides_file = ref "" in

  let spec =
    [
      ( "-generate-messages",
        Arg.Set generate_messages,
        "Generate error messages for states" );
      ( "-no-comments",
        Arg.Set no_comments,
        "Omit the auto-generated ## comments (state numbers, LR items) from \
         the output, keeping only the sentence and message" );
      ( "-census",
        Arg.Set census,
        "Print the message census: each distinct message body once, prefixed \
         by its occurrence count, sorted by message text (no sentences); the \
         delimiter-hint depth is normalized to <_>" );
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
      ( "-overrides",
        Arg.Set_string overrides_file,
        "Path to the grammar's hand-written .overrides file (step 5): \
         sentence-keyed replacement messages for states beyond heuristics. \
         Merged after generation; an override whose sentence matches no error \
         state fails the build" );
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

  let overrides =
    if !overrides_file = "" then StringMap.empty
    else load_overrides !overrides_file
  in
  (* Rot protection: every override must still key a live error state, in every
     mode, so a stale entry can never sit silently in the file. *)
  check_override_rot overrides entries;

  if !generate_messages || !stats || !census || !list_transitions then (
    if !cmly_file = "" then (
      Printf.eprintf "Error: -cmly is required for this mode.\n";
      exit 1);
    let terminals, grammar, auto = load_grammar !cmly_file in
    if !generate_messages || !stats || !census then (
      if !generate_messages then Printf.eprintf "Generating messages...\n";
      let results =
        List.map
          (fun entry ->
            let text, body, stat =
              generate_message grammar terminals ~comments:(not !no_comments)
                ~overrides entry
            in
            (entry, (text, body, stat)))
          entries
      in
      (if !generate_messages then
         (* The full [.messages] output (with comments) fed to
            [--compile-errors] keeps menhir's order; the stripped [-no-comments]
            golden is sorted by the sentence header ([entry_point: sentence]) so
            entry order stops tracking state numbers and a state merge becomes
            one clean local deletion instead of scattered delete+add pairs. *)
         let to_print =
           if !no_comments then
             List.stable_sort
               (fun (e1, _) (e2, _) ->
                 let header e =
                   e.Parse_messages.entry_point ^ ": "
                   ^ e.Parse_messages.sentence
                 in
                 String.compare (header e1) (header e2))
               results
           else results
         in
         List.iter (fun (_, (text, _, _)) -> print_string text) to_print);
      if !census then
        output_census (List.map (fun (_, (_, body, _)) -> body) results);
      if !stats then
        output_stats grammar auto
          (List.map (fun (entry, (_, _, stat)) -> (entry, stat)) results))
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
