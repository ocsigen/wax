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
module IntSet = Set.Make (Int)

type status = Direct | Lookahead | Both

(* --- Name-rendering provenance (the [names] review mode) --- *)

(* The pipeline step that produced a rendered name, so [stele names] can report
   *how* every symbol reached its wording. Mirrors the precedence documented in
   stele's README: a token alias, a [names] config entry, the list-element
   chase, the pluralised Assuming-subject rendering, the lowercase
   auto-derivation, a [class] label, or the last-resort quoted-lowercase
   fallback. Recorded alongside each rendered string by the [*_src] variants of
   the rendering functions, kept non-invasive (the plain functions project the
   string out). *)
type name_source =
  | Alias
  | Names_entry
  | Chase
  | Plural_subject
  | Auto
  | Class_label
  | Fallback

let source_label = function
  | Alias -> "alias"
  | Names_entry -> "[names]"
  | Chase -> "list-element"
  | Plural_subject -> "plural-subject"
  | Auto -> "auto-derived"
  | Class_label -> "[class]"
  | Fallback -> "quoted-fallback"

(* Where a rendered name appears. Usage is counted per position because a symbol
   can render differently in each — a list-shaped nonterminal singularises via
   the chase in the Expecting list but keeps its list/plural name as an Assuming
   subject — and a [names] entry can be dead in one position yet live in the
   other (the [LPAREN_IMPORT]/[list_of_indices] subtlety). *)
type position = Expecting | Assuming

(* One rendering of one grammar symbol in one position of one message — the raw
   material [stele names] and the config-unused stat aggregate over. [nu_credit]
   names the element a list-element chase resolved to and *its* real source: when
   [nu_source] is [Chase] the shown text comes from that element (e.g. the
   [locals] list chases to [local_decl], whose text is its [names] entry), so
   the config-unused stat credits the element and does not mis-report it as
   unused. [None] when no chase occurred. *)
type name_use = {
  nu_symbol : string;
  nu_rendered : string;
  nu_source : name_source;
  nu_position : position;
  nu_credit : (string * name_source) option;
}

(* --- Per-grammar configuration (the [-config] sidecar) --- *)

(* Everything grammar-specific that is not derivable from the [.cmly] lives in a
   hand-written [-config] file, so the generator itself is grammar-agnostic. Three
   things: readable names for symbols whose auto-derived rendering would be jargon
   or grammatically wrong ([names]); token classes collapsed to one readable label
   before the readable cap ([class …]); and the name-pattern nets the missed-hint
   lint uses to recognize an opener the alias table alone would miss
   ([opener-nets]). Absent, [empty_config] gives no curated names, no classes, and
   alias-only opener recognition — a plain but sound baseline for any grammar. *)
type net = Prefix of string | Suffix of string | Exact of string

type config = {
  names : (string, string) Hashtbl.t;
      (** readable name overrides, keyed by symbol name *)
  classes : (string * StringSet.t) list;
      (** each token class: its readable label and its member terminals, in file
          order (the first matching class wins in [classify_symbol]) *)
  opener_nets : (char * net list) list;
      (** per opener character, the name-pattern nets that also count as an
          opener of that character in the missed-hint lint *)
  wrappers : StringSet.t;
      (** escape hatch for the structural wrapper classification:
          parametric-rule base heads (the text before '(') listed here always
          classify as a menhir-generated wrapper and expand through their
          productions, even when the structural test (list- or option-shaped)
          would keep them opaque. Empty for both real grammars — their
          parameterized symbols are all genuine wrappers the structural test
          already recognises. *)
}

let empty_config =
  {
    names = Hashtbl.create 1;
    classes = [];
    opener_nets = [];
    wrappers = StringSet.empty;
  }

(* Read the [-config] file. Format (a hand-parsed line format, [#] comments,
   [[section]] headers), documented in stele's README:

     [names]        NAME = readable phrase          (one per line)
     [class LABEL]  a member terminal per line       (repeatable header)
     [opener-nets]  OPENER_CHAR KIND ARG             (KIND = prefix|suffix|exact)
     [wrappers]     a parametric-rule base head per line

   Blank lines and [#] comment lines are ignored anywhere. *)
let load_config file =
  let lines = Parse_messages.read_lines file in
  let names = Hashtbl.create 64 in
  let classes =
    ref []
    (* (label, members ref), reversed *)
  in
  let nets = Hashtbl.create 8 in
  let wrappers = ref StringSet.empty in
  let section = ref `None in
  List.iter
    (fun raw ->
      let line = String.trim raw in
      if line = "" || line.[0] = '#' then ()
      else if line.[0] = '[' && line.[String.length line - 1] = ']' then
        let inner = String.sub line 1 (String.length line - 2) |> String.trim in
        if inner = "names" then section := `Names
        else if inner = "wrappers" then section := `Wrappers
        else if inner = "opener-nets" then section := `Nets
        else if String.length inner >= 6 && String.sub inner 0 6 = "class " then (
          let label =
            String.trim (String.sub inner 6 (String.length inner - 6))
          in
          classes := (label, ref StringSet.empty) :: !classes;
          section := `Class)
        else failwith (Printf.sprintf "config: unknown section header %S" line)
      else
        match !section with
        | `None ->
            failwith
              (Printf.sprintf "config: line outside any section: %S" line)
        | `Names -> (
            match String.index_opt line '=' with
            | None ->
                failwith (Printf.sprintf "config [names]: no '=' in %S" line)
            | Some i ->
                let key = String.trim (String.sub line 0 i) in
                let value =
                  String.trim
                    (String.sub line (i + 1) (String.length line - i - 1))
                in
                Hashtbl.replace names key value)
        | `Class -> (
            match !classes with
            | (_, members) :: _ -> members := StringSet.add line !members
            | [] -> assert false)
        | `Wrappers -> wrappers := StringSet.add line !wrappers
        | `Nets -> (
            match
              String.split_on_char ' ' line |> List.filter (fun s -> s <> "")
            with
            | [ ch; kind; arg ] when String.length ch = 1 ->
                let net =
                  match kind with
                  | "prefix" -> Prefix arg
                  | "suffix" -> Suffix arg
                  | "exact" -> Exact arg
                  | _ ->
                      failwith
                        (Printf.sprintf "config [opener-nets]: unknown kind %S"
                           kind)
                in
                let c = ch.[0] in
                let existing = try Hashtbl.find nets c with Not_found -> [] in
                Hashtbl.replace nets c (existing @ [ net ])
            | _ ->
                failwith
                  (Printf.sprintf
                     "config [opener-nets]: expected 'CHAR KIND ARG': %S" line)))
    lines;
  {
    names;
    classes = List.rev_map (fun (l, m) -> (l, !m)) !classes;
    opener_nets = Hashtbl.fold (fun c nets acc -> (c, nets) :: acc) nets [];
    wrappers = !wrappers;
  }

let net_matches token = function
  | Prefix p -> String.starts_with ~prefix:p token
  | Suffix s -> String.ends_with ~suffix:s token
  | Exact e -> token = e

(* --- Exact Grammar (menhirSdk / .cmly) --- *)

(* The grammar knowledge the continuation computation needs, read from the
   [.cmly] file rather than reconstructed from the LR items that happen to
   appear in error states (the old scrape was provably incomplete: a
   menhir-generated symbol whose defining item was absent from every sampled
   state lost its continuations, and nullability was a name-prefix guess that
   missed opaque nullable nonterminals like [statement_list]). *)
type gram = {
  is_terminal : string -> bool;
  is_nonterminal : string -> bool;
      (** a user- or menhir-named nonterminal the grammar defines (used by the
          config rot guard to accept a [names] key that names a nonterminal) *)
  all_terminals : StringSet.t;
      (** every real terminal name (the error/EOF pseudo-tokens included), used
          by the config rot guard's [opener-nets] pattern check *)
  all_nonterminals : StringSet.t;
      (** every nonterminal name (parametric instantiations included), used by
          the config rot guard's [wrappers] head check *)
  nullable : string -> bool;  (** false for terminals and unknown names *)
  productions : string -> string list list;
      (** each right-hand side as a list of surface symbol names *)
  is_generated : string -> bool;
      (** a menhir-generated *wrapper* — an inlined anonymous rule, or a
          parametric-rule instantiation whose body is list- or option-shaped
          over its element (see [symbol_is_generated]). Expand it through its
          productions. A user-named nonterminal, and a phantom-parameterized
          instantiation whose body is a real construct (not a wrapper shape),
          stay opaque and render by their base name. *)
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

(* Check if a symbol involves an anonymous symbol generated by Menhir (a bare
   [__anonymous_N], or one that survived inside a wrapper instantiation like
   [option(__anonymous_3)]); [__anonymous] can appear anywhere in the name. *)
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

(* Is [s] a menhir-generated *wrapper* — a symbol to expand through its
   productions rather than name opaquely? The classification is STRUCTURAL, not
   nominal (the old test keyed on '(' alone, which cannot tell a stdlib wrapper
   from a phantom-parameterized user rule like [function_type(in_type)] — see the
   15c DONE note in ERROR-MESSAGES.md). Three ways to qualify:

   - an inlined anonymous rule ([__anonymous_*], possibly nested inside an
     instantiation) — always expanded, as before;
   - a parametric instantiation (name carries '(') whose body is *list-shaped*
     over its element: directly self-recursive ([list(X)], [nonempty_list(X)],
     [semi_list(X)], [separated_nonempty_list(_,X)] and wax's own
     [separated_nonempty_list_trailing(_,X)]), or a single production that IS a
     stdlib list wrapper ([loption(separated_…)]);
   - a parametric instantiation whose body is *option-shaped* ([ε | X]): an empty
     production and every production empty or a single symbol ([option(X)],
     [boption(TOKEN)], [loption(X)]).

   Everything else — a user-named nonterminal, and a parametric instantiation
   whose body is a real construct (the phantom-parameter case) — is opaque and
   renders by its base name. The [wrappers] config set is an escape hatch: a base
   head listed there is forced to expand (applied by [apply_wrapper_overrides] at
   the call site, where the config is known). *)
let symbol_is_generated ~productions s =
  involves_anonymous s
  || String.contains s '('
     &&
     let prods = productions s in
     let self_recursive = List.exists (List.exists (fun x -> x = s)) prods in
     let single_list_wrapper =
       List.exists
         (function
           | [ x ] -> contains_sub x "list(" || contains_sub x "separated_"
           | _ -> false)
         prods
     in
     let option_shaped =
       List.exists (function [] -> true | _ -> false) prods
       && List.for_all (function [] | [ _ ] -> true | _ -> false) prods
     in
     self_recursive || single_list_wrapper || option_shaped

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
  let productions_of s = try Hashtbl.find prod_tbl s with Not_found -> [] in
  let gram =
    {
      is_terminal = (fun s -> Hashtbl.mem terminal_names s);
      is_nonterminal = (fun s -> Hashtbl.mem prod_tbl s);
      all_terminals =
        Hashtbl.fold
          (fun n () acc -> StringSet.add n acc)
          terminal_names StringSet.empty;
      all_nonterminals =
        Hashtbl.fold
          (fun n _ acc -> StringSet.add n acc)
          prod_tbl StringSet.empty;
      nullable =
        (fun s -> try Hashtbl.find nullable_tbl s with Not_found -> false);
      productions = productions_of;
      is_generated = symbol_is_generated ~productions:productions_of;
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

(* --- List-element chase (singular Expecting wording) --- *)

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

(* Standard bracket pairing: the opening-delimiter character a closing one
   terminates. Grammar-agnostic (plain ASCII brackets), so it stays built in. *)
let opener_of_closer_char = function
  | ')' -> Some '('
  | ']' -> Some '['
  | '}' -> Some '{'
  | _ -> None

(* Derive the closer terminals from the grammar's token aliases (move 1, the
   symmetric mirror of the opener rule): any terminal whose alias ENDS with a
   closing-delimiter character, paired with the matching opener character — so a
   multi-character closer like [|]] ('|]') is recognised just as a compound
   opener like [(then] is by its first character. Replaces the old
   hand-maintained RBRACE/RBRACKET/RPAREN name table (which went stale) — a
   grammar that aliases its delimiters gets hints for free, one that does not
   simply gets none. Sorted for a deterministic tie-break order between closers
   valid in the same state. *)
let closers_of terminals =
  Hashtbl.fold
    (fun name alias acc ->
      let n = String.length alias in
      if n >= 1 then
        match opener_of_closer_char alias.[n - 1] with
        | Some o -> (name, o) :: acc
        | None -> acc
      else acc)
    terminals []
  |> List.sort compare

(* The opening delimiter a closer terminates, from the derived [closers] table
   ([List.assoc]-style): a ')' closes a '(', etc. *)
let opener_char_of_closer closers closer = List.assoc_opt closer closers

(* The opener character a token's alias begins with ([(]/[\[]/[{]), if any — the
   opener-classification net, the mirror of [closers_of]'s closer test. *)
let opener_char_of terminals name =
  match Hashtbl.find_opt terminals name with
  | Some a
    when String.length a > 0 && (a.[0] = '(' || a.[0] = '[' || a.[0] = '{') ->
      Some a.[0]
  | _ -> None

(* Move 2: EXACT opener<->closer pairs derived from the grammar's productions,
   not guessed from the shared bracket kind. In each production's right-hand
   side, a closer-classified symbol mates the nearest still-open
   opener-classified symbol of the SAME bracket character (proper nesting within
   the rhs — a stack pop); collected over every production. The result maps each
   closer token to the SET of opener tokens that mate it (a set because an opener
   may reach the same closer through several productions; a closer may have
   several distinct opener mates, e.g. wasm's ')' pairs with '(', '(then',
   '(param', …). This is what lets [find_matching_depth] balance per exact pair
   so a plain '[' and a compound '[|' that share the '[' kind stop cross-matching.

   Ambiguity: the nearest-following-closer-of-the-same-kind rule gives each
   opener occurrence exactly one mate per production, so a production is never
   ambiguous; an opener whose mate differs ACROSS productions simply contributes
   several entries to the (set-valued) table, which is fine. In wax/wasm/calc no
   opener reaches two different closers, so every mate set is a clean bracket
   family. *)
let mates_of grammar terminals closers =
  let tbl = Hashtbl.create 16 in
  let add closer opener =
    let cur = try Hashtbl.find tbl closer with Not_found -> StringSet.empty in
    Hashtbl.replace tbl closer (StringSet.add opener cur)
  in
  StringSet.iter
    (fun nt ->
      List.iter
        (fun rhs ->
          (* Stack of (opener_name, opener_char) still open in this rhs. *)
          let stack = ref [] in
          List.iter
            (fun sym ->
              match List.assoc_opt sym closers with
              | Some oc ->
                  (* A closer of opener-char [oc]: pop the nearest open opener of
                     that character and record the mate. A closer with no open
                     mate in this rhs (e.g. a stray ')' balanced by a different
                     production) contributes nothing. *)
                  let rec pop = function
                    | (oname, ochar) :: rest when ochar = oc ->
                        add sym oname;
                        rest
                    | keep :: rest -> keep :: pop rest
                    | [] -> []
                  in
                  stack := pop !stack
              | None -> (
                  (* A closer classification wins over an opener one; only
                     otherwise treat the symbol as a possible opener. *)
                  match opener_char_of terminals sym with
                  | Some c -> stack := (sym, c) :: !stack
                  | None -> ()))
            rhs)
        (grammar.productions nt))
    grammar.all_nonterminals;
  tbl

let mates_of_closer mates closer =
  try Hashtbl.find mates closer with Not_found -> StringSet.empty

(*
   Find the depth and matching opener token for a given closer, balancing per
   EXACT pair (move 2): only a token in [closer]'s mate set counts as one of its
   openers, and only [closer] itself counts as a nested same-pair closer — so
   delimiters of any OTHER bracket pair are transparent to the scan (properly
   nested by the LR grammar, they never straddle this pair's opener).

   Invariant: scanning the (reversed) stack suffix from the top, [balance] is the
   number of unmatched occurrences of [closer] seen so far. On each token: [closer]
   raises the balance; a mate opener lowers it when balance > 0 (it closed a
   nested [closer]) or, at balance 0, IS the opener we seek; any other token is
   ignored. Depth is the 1-based index from the top of the stack; every token
   counts as depth 1. Returns the opener's depth paired with its token name.
*)
let find_matching_depth mates sentence closer =
  let tokens =
    String.split_on_char ' ' sentence
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let reversed = List.rev tokens in
  let openers = mates_of_closer mates closer in
  if StringSet.is_empty openers then None
  else
    let rec scan depth balance items =
      match items with
      | [] -> None (* Not found *)
      | token :: rest ->
          let current_depth = depth + 1 in
          if token = closer then scan current_depth (balance + 1) rest
          else if StringSet.mem token openers then
            if balance > 0 then scan current_depth (balance - 1) rest
            else Some (current_depth, token)
          else scan current_depth balance rest
    in
    scan 0 0 reversed

(* --- Message Generation --- *)

let format_human_list items =
  match List.rev items with
  | [] -> ""
  | [ x ] -> x
  | last :: rest -> String.concat ", " (List.rev rest) ^ ", or " ^ last

(* Curated readable name for a symbol whose auto-derived rendering would be
   internal jargon or grammatically wrong (e.g. "a blockinstr", "a mem limits");
   [None] falls through to the derivation in [get_readable_name]. Read from the
   [-config] file's [names] section rather than hard-coded, so the generator
   itself is grammar-agnostic. *)
let special_name cfg s = Hashtbl.find_opt cfg.names s

(* Collapse a token class (e.g. the many infix operators) into a single readable
   label *before* the <=5 cap, so a state whose FOLLOW is "a closer or any
   operator" reads "Expecting ')', or an operator." instead of overflowing to the
   generic fallback. The classes are read from the [-config] file ([class LABEL]
   sections); a token in no class returns [None] and keeps its precise spelling.
   The first class the token appears in wins (file order). *)
let classify_symbol cfg s =
  List.find_map
    (fun (label, members) ->
      if StringSet.mem s members then Some label else None)
    cfg.classes

(* Core rendering with provenance. Returns the readable string paired
   with the pipeline step that produced it; [get_readable_name] projects the
   string. Precedence: token alias, [names] entry, lowercase auto-derivation,
   quoted-lowercase fallback. *)
let get_readable_name_src cfg terminals s =
  match Hashtbl.find_opt terminals s with
  | Some a -> (Printf.sprintf "'%s'" a, Alias)
  | None -> (
      (* An opaque parameterized instantiation (a phantom-parameter split like
         [function_type(in_type)]) renders by its base head: the [names] lookup
         and the noun-phrase derivation see [function_type], not the argument
         list. Terminals never carry a '(', so this only affects nonterminals;
         wrapper instantiations are expanded upstream and never reach here. *)
      let s = base_symbol_name s in
      match special_name cfg s with
      | Some name -> (name, Names_entry)
      | None ->
          if String.lowercase_ascii s = s then
            (* Non-terminals: "some_name" -> "a/an some name" *)
            let parts = String.split_on_char '_' s in
            let parts = List.filter (fun p -> p <> "") parts in
            if parts = [] then (s, Auto)
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
                  if is_plural then (name, Auto)
                  else if List.mem c [ 'a'; 'e'; 'i'; 'o'; 'u' ] then
                    ("an " ^ name, Auto)
                  else ("a " ^ name, Auto)
              | _ -> (name, Auto)
          else
            (* Keywords/Other Terminals: "TOKEN" -> "'token'" *)
            ("'" ^ String.lowercase_ascii s ^ "'", Fallback))

(* Rendering for the *Expecting* position. What the user types next is
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
(* Returns (rendered string, display source, credit). When the list-element chase fires
   the display source is [Chase] (so the review table shows the mechanism that
   overrode the list name), and the credit is the element the chase resolved to
   paired with its *real* source — what actually produced the text. *)
let rec expecting_name_src ?(visited = StringSet.empty) cfg terminals gram s =
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
        let r, elem_src, elem_credit =
          expecting_name_src ~visited:(StringSet.add s visited) cfg terminals
            gram elem
        in
        (* The credit is the deepest resolution: propagate the element's own
           credit if it was itself chased, else the element and its real
           source. *)
        let credit =
          match elem_credit with Some c -> c | None -> (elem, elem_src)
        in
        (r, Chase, Some credit)
    | None ->
        let r, src = get_readable_name_src cfg terminals s in
        (r, src, None)
  else
    let r, src = get_readable_name_src cfg terminals s in
    (r, src, None)

let expecting_name ?(visited = StringSet.empty) cfg terminals gram s =
  let r, _, _ = expecting_name_src ~visited cfg terminals gram s in
  r

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
let subject_name_src cfg terminals gram s =
  if gram.is_generated s then
    match chase_list_element gram s with
    | Some elem ->
        ( pluralize_phrase
            (strip_article (expecting_name cfg terminals gram elem)),
          Plural_subject )
    | None -> ("a list", Plural_subject)
  else get_readable_name_src cfg terminals s

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
          [.overrides] file. An overridden entry is excluded from the fallback
          counters (it is no longer a generic fallback) and from the
          soundness/jargon self-lints, which cannot parse free prose — see the
          override-merge site in [generate_message] for the claim-soundness
          responsibility note. *)
  fallback_symbols : string list;
      (** The readable expected list of a not-overridden generic-fallback entry
          (empty, or over the ≤5 cap) — what [-list-fallbacks] shows an override
          author as candidates; [] for any other entry. *)
  collapsed_classes : StringSet.t;
      (** Configured class labels whose collapse fired in this entry's computed
          expected list (>=2 members present in the chosen continuation tier).
          Independent of whether the resulting message was ultimately shown: an
          override or an over-cap overflow can supersede the collapsed phrase,
          yet the class is not dormant — its members still co-occur in a real
          state. So this counts the collapse *computation*, not the shown text.
          The dormancy stat tallies, per class, how many entries carry it; a
          permanently empty set is a class whose members stopped co-occurring
          (going quiet), which the stats ratchet then makes visible. *)
  raw_terminals : string list;
      (** The pre-classing raw terminal claims of the chosen continuation tier
          (expected_raw restricted to terminals), for every entry regardless of
          emission or override. The [-suggest-classes] clustering is over these
          raw sets. *)
  readable_len : int;
      (** The readable expected-list length with the *current* classes applied
          (List.length expected_symbols), for every entry — the
          [-suggest-classes] impact simulation's baseline against the <=5 cap.
      *)
  name_uses : name_use list;
      (** Every symbol this entry's *emitted* message actually rendered, with
          its rendered form, provenance, and position. Empty for an override
          (free prose) and for a generic fallback ("Syntax error", no symbol
          shown) — except that an over-cap fallback under a spurious reduction
          still shows its Assuming subject, which is recorded. The [names]
          review and the config-unused stat aggregate over these. *)
}

(* Would [token] plausibly open the construct [closer] terminates? Broader than
   the alias test in [find_matching_depth] on purpose: this is the lint's net for
   openers the alias table alone would miss. The alias-driven part is built in (a
   token whose alias begins with the opener character); the extra name-pattern
   nets come from the [-config] file's [opener-nets] section, keyed by opener
   character, so nothing here is grammar-specific. *)
let opener_like cfg closers terminals closer token =
  match opener_char_of_closer closers closer with
  | None -> false
  | Some opener_c -> (
      let alias_starts c =
        match Hashtbl.find_opt terminals token with
        | Some a -> String.length a > 0 && a.[0] = c
        | None -> false
      in
      alias_starts opener_c
      ||
      match List.assoc_opt opener_c cfg.opener_nets with
      | None -> false
      | Some nets -> List.exists (net_matches token) nets)

(* Does the known stack suffix contain an opener-like token with no matching
   closer? Same balance scan as [find_matching_depth], but with the broad
   [opener_like] net as the opener test — so the lint reports a genuinely
   unmatched opener [find_matching_depth]'s (narrower) table missed, not a token
   that merely appears somewhere in a balanced pair (e.g. the matched
   [LPAREN parameter_list RPAREN] suffix, which needs no hint). [sentence] is the
   space-joined known stack suffix — split into tokens as [find_matching_depth]
   does, since the raw stack lines glue several tokens together. *)
let unmatched_opener_like cfg closers terminals closer sentence =
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
        else if opener_like cfg closers terminals closer token then
          if balance > 0 then scan (balance - 1) rest else true
        else scan balance rest
  in
  scan 0 reversed

let renders_as_jargon cfg terminals s =
  String.uppercase_ascii s = s
  && (not (Hashtbl.mem terminals s))
  && special_name cfg s = None
  && String.contains s '_'

(* --- Hand-written overrides (the sanctioned escape hatch) --- *)

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

(* The [-config] sidecar's counterpart to [check_override_rot]: every entry must
   still name a symbol the grammar has, so a config left behind by a grammar
   change fails the build instead of firing on nothing. A [class] member must be
   a terminal; a [names] key a terminal or nonterminal; an [opener-nets] pattern
   must match at least one terminal (an unmatched net is a silently dead lint
   rule). Run at [-config] load, so it needs the [.cmly] every config-consuming
   mode already reads. Error style mirrors [check_override_rot]: a hard failure
   naming the file, section, and stale entry. *)
let check_config_rot ~file gram cfg =
  let stale section entry =
    failwith
      (Printf.sprintf
         "config %s [%s]: %S names no symbol of this grammar (stale entry — \
          remove or fix it)"
         file section entry)
  in
  Hashtbl.iter
    (fun key _ ->
      if not (gram.is_terminal key || gram.is_nonterminal key) then
        stale "names" key)
    cfg.names;
  List.iter
    (fun (label, members) ->
      StringSet.iter
        (fun m ->
          if not (gram.is_terminal m) then
            stale (Printf.sprintf "class %s" label) m)
        members)
    cfg.classes;
  List.iter
    (fun (ch, nets) ->
      List.iter
        (fun net ->
          if
            not
              (StringSet.exists (fun t -> net_matches t net) gram.all_terminals)
          then
            let pat =
              match net with
              | Prefix p -> Printf.sprintf "%c prefix %s" ch p
              | Suffix s -> Printf.sprintf "%c suffix %s" ch s
              | Exact e -> Printf.sprintf "%c exact %s" ch e
            in
            stale "opener-nets" pat)
        nets)
    cfg.opener_nets;
  (* A [wrappers] head must be the base of at least one parameterized nonterminal
     (a lone head, no '(', is never itself a nonterminal), else the escape hatch
     is dead. *)
  StringSet.iter
    (fun head ->
      if
        not
          (StringSet.exists
             (fun n -> String.contains n '(' && base_symbol_name n = head)
             gram.all_nonterminals)
      then stale "wrappers" head)
    cfg.wrappers

(* Fold the [wrappers] config escape hatch into a grammar's classification: a
   parameterized instantiation whose base head is listed always classifies as a
   wrapper (expand through productions), on top of the structural test. The config
   is not known when [load_grammar] runs, so this is applied at the call site once
   both are loaded; a no-op when [wrappers] is empty (both real grammars). *)
let apply_wrapper_overrides cfg gram =
  if StringSet.is_empty cfg.wrappers then gram
  else
    {
      gram with
      is_generated =
        (fun s ->
          gram.is_generated s
          || String.contains s '('
             && StringSet.mem (base_symbol_name s) cfg.wrappers);
    }

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

let generate_message cfg closers mates grammar terminals ~comments ~overrides
    entry =
  let d = entry.Parse_messages.data in

  (* Heuristic: Formatting Logic. [subject_name] renders the Assuming subject
     (the whole completed construct — a user-named nonterminal by name, a
     generated list wrapper by its pluralised element); [expecting_name] renders
     the Expecting list (one element — singularises a list-shaped name). *)
  let subject_name_src = subject_name_src cfg terminals grammar in
  let expecting_name_src = expecting_name_src cfg terminals grammar in

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
          match classify_symbol cfg s with
          | Some c ->
              StringMap.update c
                (function None -> Some 1 | Some n -> Some (n + 1))
                acc
          | None -> acc)
        StringMap.empty expected_raw
    in
    (* Per raw symbol, its rendered form and the pipeline step that produced it:
       a class label when the class collapse fires (>=2 members
       present), else the Expecting-position rendering. Feeds both the shown
       [expected_symbols] and the [names] review's per-symbol provenance. *)
    let rendered =
      List.map
        (fun s ->
          match classify_symbol cfg s with
          | Some c when StringMap.find c class_counts >= 2 ->
              (s, c, Class_label, None)
          | _ ->
              let r, src, credit = expecting_name_src s in
              (s, r, src, credit))
        expected_raw
    in
    let expected_symbols =
      rendered
      |> List.map (fun (_, r, _, _) -> r)
      |> List.sort_uniq String.compare
    in
    (* The classes whose collapse actually fired (>=2 members present): the
       dormancy stat's per-entry contribution. *)
    let collapsed =
      StringMap.fold
        (fun c n acc -> if n >= 2 then StringSet.add c acc else acc)
        class_counts StringSet.empty
    in
    (expected_raw, expected_symbols, collapsed, rendered)
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
  let expected_raw_agg, exp_agg, collapsed_agg, rendered_agg =
    expected_of vs_agg
  in
  let valid_symbols, expected_raw, expected_symbols, collapsed_classes, rendered
      =
    let n = List.length exp_agg in
    if n >= 1 && n <= 5 then
      (vs_agg, expected_raw_agg, exp_agg, collapsed_agg, rendered_agg)
    else
      let vs_c =
        symbols_of grammar.is_generated |> StatusMap.bindings |> List.map fst
      in
      let expected_raw_c, exp_c, collapsed_c, rendered_c = expected_of vs_c in
      (vs_c, expected_raw_c, exp_c, collapsed_c, rendered_c)
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

  (* Heuristic: Unclosed Delimiters. [closers] is derived from the token aliases
     (a terminal aliased ')'/']'/'}' paired with its opener character), so this
     handles whatever delimiters the grammar declares, in a deterministic
     tie-break order. *)
  let check_unclosed (closer, opener_char) =
    if List.mem closer valid_symbols then
      match find_matching_depth mates sentence closer with
      | Some (depth, opener_tok) ->
          (* The hint names — and the runtime underlines — the opener's FULL
             alias (move 3). When the closer has a UNIQUE mate, that mate is the
             opener, so print its alias verbatim (a compound '[|' reads "This
             '[|' …", underlined two characters). When the closer has SEVERAL
             mates (wasm's ')' pairs with '(', '(then', …), no single alias
             names them, so fall back to the shared opener character — which is
             exactly today's rendering, keeping those goldens byte-identical. *)
          let alias =
            if StringSet.cardinal (mates_of_closer mates closer) = 1 then
              match Hashtbl.find_opt terminals opener_tok with
              | Some a -> a
              | None -> String.make 1 opener_char
            else String.make 1 opener_char
          in
          Some (depth, alias)
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
         inside. A stable sort keeps [closers]' deterministic tie-break order. *)
      List.filter_map check_unclosed closers
      |> List.stable_sort (fun (d1, _) (d2, _) -> compare d1 d2)
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
     innermost during the prune audit: outermost wins because the Expecting token is the
     FOLLOW of the outermost frame, so naming that frame keeps hedge and
     expectation coherent ("the instructions are complete, expecting 'end'"),
     whereas the innermost names the construct at the edit point but pairs it with
     a FOLLOW token from a wider frame ("the parameters without bindings are
     complete, expecting 'end'" — incoherent, and jargon). Outermost also keeps
     the step-4 "block type is complete" messages and avoids the raw-grammar
     "plaininstr"/"parameters without bindings" subjects the innermost surfaced on
     the deep cascades. *)
  let message_body, subject_marker =
    match List.rev d.spurious_reductions with
    | [] -> (base_message, None)
    | last :: _ ->
        let raw_name = fst (subject_name_src last.symbol) in
        let name, verb =
          if String.length raw_name > 2 && String.sub raw_name 0 2 = "a " then
            (String.sub raw_name 2 (String.length raw_name - 2), "is")
          else if String.length raw_name > 3 && String.sub raw_name 0 3 = "an "
          then (String.sub raw_name 3 (String.length raw_name - 3), "is")
          else if String.length raw_name > 0 && String.get raw_name 0 = '\''
          then (raw_name, "is")
          else (raw_name, "are")
        in
        let body =
          Printf.sprintf "Assuming that the %s %s complete, %s" name verb
            (if base_message = "Syntax error" then "syntax error."
             else String.uncapitalize_ascii base_message)
        in
        (* Emit a [<^N>] subject marker so the runtime underlines the completed
           construct itself. Its stack cell is the top of the post-reduction
           stack (depth 1): the *outermost* spurious reduction (this [last] one,
           the outermost of menhir's innermost→outermost record) did the last
           goto, pushing its LHS on top. The marker resolves that cell — it does
           not consume a stack slot, so any [<N>] delimiter-hint depth is
           unaffected. The label wording is deictic ("this"/"these", agreeing
           with the sentence's is/are); the sentence itself keeps the plain "the
           X is complete" phrasing, so an epsilon subject the runtime drops (a
           zero-width span, e.g. empty exports) leaves a coherent message with no
           dangling deixis. *)
        let deictic =
          if verb = "are" then "these " ^ name else "this " ^ name
        in
        (body, Some (Printf.sprintf "<^1>%s" deictic))
  in

  (* Append the located markers under the message: the [<^N>] hedge subject
     first, then any [<N>] delimiter hint. The order is the order the runtime
     surfaces the labels (subject before opener). *)
  let generated_message =
    let subject_lines =
      match subject_marker with Some m -> [ m ] | None -> []
    in
    let hint_lines =
      match unclosed_details with
      | Some (depth, opener) ->
          (* Locate the opener of the construct the error sits inside, without
             claiming it is unmatched: the same error state is reached both when
             the construct is genuinely unclosed (an EOF cut it short) and when a
             later token inside an already-closed construct is invalid, so a
             "might be unmatched" reading would be false in the latter, common
             case. A purely locational hint is true in both. *)
          [
            Printf.sprintf "<%d>This '%s' opens the enclosing construct." depth
              opener;
          ]
      | None -> []
    in
    String.concat "\n" ((message_body :: subject_lines) @ hint_lines)
  in

  (* Hand-override merge: if the sanctioned [.overrides] file supplies a
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
          && find_matching_depth mates sentence closer = None
          && unmatched_opener_like cfg closers terminals closer
               (String.concat " " d.stack_suffix))
        (List.map fst closers)
  in
  let jargon =
    if emitted then
      List.fold_left
        (fun acc s ->
          if renders_as_jargon cfg terminals s then StringSet.add s acc else acc)
        StringSet.empty expected_raw
    else StringSet.empty
  in
  (* Per-symbol rendering provenance, one [name_use] per symbol the
     *shown* message renders. The Expecting list surfaces only when emitted (the
     [rendered] list carries the chosen tier's symbols with their source); the
     Assuming subject surfaces whenever a spurious reduction was hedged and the
     entry is not overridden — including an over-cap fallback, whose message is
     still "Assuming that the X is complete, syntax error." An override shows
     free prose, so it contributes nothing. *)
  let name_uses =
    let expecting =
      if emitted then
        List.map
          (fun (sym, r, src, credit) ->
            {
              nu_symbol = sym;
              nu_rendered = r;
              nu_source = src;
              nu_position = Expecting;
              nu_credit = credit;
            })
          rendered
      else []
    in
    let assuming =
      if (not overridden) && d.spurious_reductions <> [] then
        match List.rev d.spurious_reductions with
        | last :: _ ->
            let r, src = subject_name_src last.symbol in
            [
              {
                nu_symbol = last.symbol;
                nu_rendered = r;
                nu_source = src;
                nu_position = Assuming;
                nu_credit = None;
              };
            ]
        | [] -> []
      else []
    in
    expecting @ assuming
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
      fallback_symbols =
        (if (not overridden) && (n_expected = 0 || n_expected > 5) then
           expected_symbols
         else []);
      collapsed_classes;
      raw_terminals = List.filter grammar.is_terminal expected_raw;
      readable_len = n_expected;
      name_uses;
    }
  in
  (* [full_message] is returned separately for the census, which counts
     distinct message bodies without the per-entry sentence header. *)
  (Buffer.contents buf, full_message, stat)

(* Analysis: List all possible continuations for states, indicating spurious reductions. *)
let analyze_transitions closers mates grammar entries =
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
            if List.mem_assoc s closers then
              match find_matching_depth mates sentence s with
              | Some (depth, _) -> Printf.sprintf " [depth: %d]" depth
              | None -> " [mismatch?]"
            else ""
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

(* --- Names review and staleness --- *)

(* Per [names] config key, how many times its curated phrase was the *winning*
   rendering in each position (i.e. a [name_use] with source [Names_entry]). A
   key that wins in neither position fires nothing — the config-unused ratchet
   target — though that is not always a bug: a list-shaped name is
   Expecting-dead because the list-element chase overrides it, yet can be Assuming-live as
   the completed-construct subject. Returned sorted by key as
   (key, expecting_count, assuming_count) over *every* configured [names] entry,
   so an unused one shows (0, 0). *)
let names_fire_counts cfg uses =
  let bump sym pos m =
    let e, a =
      match StringMap.find_opt sym m with Some p -> p | None -> (0, 0)
    in
    StringMap.add sym
      (match pos with Expecting -> (e + 1, a) | Assuming -> (e, a + 1))
      m
  in
  let counts =
    List.fold_left
      (fun m u ->
        (* A [names] entry fires either as the winning source directly, or as
           the element a chase resolved to (credited so [local_decl] under the
           [locals] chase is not mis-flagged as unused). *)
        let m =
          if u.nu_source = Names_entry then bump u.nu_symbol u.nu_position m
          else m
        in
        match u.nu_credit with
        | Some (elem, Names_entry) -> bump elem u.nu_position m
        | _ -> m)
      StringMap.empty uses
  in
  Hashtbl.fold (fun k _ acc -> k :: acc) cfg.names []
  |> List.sort_uniq String.compare
  |> List.map (fun k ->
      let e, a =
        match StringMap.find_opt k counts with Some p -> p | None -> (0, 0)
      in
      (k, e, a))

(* Aggregate the per-entry self-lints into the quality summary pinned by the
   promoted [parser_messages.stats.expected] goldens: regressions (a new
   fallback state, a lost hint, a jargon token) fail `dune runtest`;
   improvements are accepted with `dune promote`. *)
let output_stats cfg gram auto results =
  let count f = List.length (List.filter (fun (_, s) -> f s) results) in
  Printf.printf "entries: %d\n" (List.length results);
  Printf.printf "with an expected list: %d\n" (count (fun s -> s.expecting));
  Printf.printf "using the spurious-reduction template: %d\n"
    (count (fun s -> s.assuming));
  (* Cascade depth = the number of spurious reductions folded before the error
     is reported (the length of the "Assuming …" chain). A deep cascade means
     the hedge names a construct far from where the user was editing; the prune
     audit watches these so over-annotation is measurable. *)
  let cascade_depths =
    List.map
      (fun (entry, _) ->
        List.length entry.Parse_messages.data.spurious_reductions)
      results
  in
  Printf.printf "entries with cascade depth >= 4: %d\n"
    (List.length (List.filter (fun d -> d >= 4) cascade_depths));
  Printf.printf "max cascade depth: %d\n" (List.fold_left max 0 cascade_depths);
  (* Hand-written overrides. The fallback counters below exclude these
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
      with_uncovered;
  (* Dormancy ratchet: one line per configured token class, in file
     order, giving how many entries had the class collapse fire in their computed
     expected list (>=2 members co-occurring). This counts the collapse
     computation, not the shown text — an override or an over-cap overflow may
     supersede the phrase (as every wax operator state currently does), yet the
     class is live while its members still co-occur. N=0 is legitimate (a class
     waiting for a qualifying state) but now visible, so a class that goes quiet
     after a grammar change shows up as a golden diff. A grammar with no classes
     prints nothing. *)
  List.iter
    (fun (label, _) ->
      Printf.printf "class %S: collapsed in %d entries\n" label
        (count (fun s -> StringSet.mem label s.collapsed_classes)))
    cfg.classes;
  (* Names-staleness ratchet: the [names] mode counts, per configured
     entry, how often its curated phrase actually won in each position. An entry
     unused in *both* positions fires nothing and is the ratchet target — going
     quiet after a grammar change becomes a failing runtest diff, like class
     dormancy. Each unused entry is listed with its per-position detail (both
     "unused" here; the [names] mode's full table shows any dead-in-one-position
     entry, which still fires and so is not counted here). *)
  let uses = List.concat_map (fun (_, s) -> s.name_uses) results in
  let fire = names_fire_counts cfg uses in
  let unused = List.filter (fun (_, e, a) -> e = 0 && a = 0) fire in
  Printf.printf "names configured: %d, unused: %d\n" (List.length fire)
    (List.length unused);
  List.iter
    (fun (k, e, a) ->
      let show n = if n = 0 then "unused" else string_of_int n in
      Printf.printf "  %s (expecting: %s, assuming: %s)\n" k (show e) (show a))
    unused

(* The [names] review mode: a table of every symbol that surfaces in
   the emitted messages — its rendered form, the pipeline step that produced it,
   and how many times it appears in each position — sorted by symbol, then an
   [unused [names] entries] section listing configured entries whose curated
   phrase won in neither position. The audit surface for both directions:
   awkward auto-derived or fallback renderings that deserve a [names] entry, and
   [names] entries nothing uses. Output is plain aligned text, grep-able and
   stable (no box drawing). *)
let output_names ~overrides_active cfg results =
  let uses = List.concat_map (fun (_, s) -> s.name_uses) results in
  (* Aggregate by (symbol, rendered, source): a symbol that renders one way in
     the Expecting list and another as an Assuming subject (a list-shaped name)
     yields two rows, each honest about its own rendering and source. *)
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun u ->
      let key = (u.nu_symbol, u.nu_rendered, u.nu_source) in
      let e, a = try Hashtbl.find tbl key with Not_found -> (0, 0) in
      let e, a =
        match u.nu_position with
        | Expecting -> (e + 1, a)
        | Assuming -> (e, a + 1)
      in
      Hashtbl.replace tbl key (e, a))
    uses;
  let rows =
    Hashtbl.fold
      (fun (sym, r, src) (e, a) acc -> (sym, r, src, e, a) :: acc)
      tbl []
    |> List.sort (fun (s1, r1, _, _, _) (s2, r2, _, _, _) ->
        match String.compare s1 s2 with 0 -> String.compare r1 r2 | c -> c)
  in
  let colw sel dflt =
    List.fold_left (fun w row -> max w (String.length (sel row))) dflt rows
  in
  let wsym = colw (fun (s, _, _, _, _) -> s) (String.length "SYMBOL") in
  let wren = colw (fun (_, r, _, _, _) -> r) (String.length "RENDERED") in
  let wsrc =
    colw (fun (_, _, src, _, _) -> source_label src) (String.length "SOURCE")
  in
  Printf.printf "%-*s  %-*s  %-*s  %9s  %8s\n" wsym "SYMBOL" wren "RENDERED"
    wsrc "SOURCE" "EXPECTING" "ASSUMING";
  List.iter
    (fun (sym, r, src, e, a) ->
      Printf.printf "%-*s  %-*s  %-*s  %9d  %8d\n" wsym sym wren r wsrc
        (source_label src) e a)
    rows;
  let fire = names_fire_counts cfg uses in
  let unused = List.filter (fun (_, e, a) -> e = 0 && a = 0) fire in
  Printf.printf "\nunused [names] entries:\n";
  if unused = [] then Printf.printf "  (none)\n"
  else
    List.iter
      (fun (k, _, _) ->
        Printf.printf "  %s = %s\n" k
          (match Hashtbl.find_opt cfg.names k with Some v -> v | None -> ""))
      unused;
  (* When an [.overrides] file is in effect, its entries carry hand-written prose
     whose per-symbol renderings the naming table does not record; note their
     count so a hand run of [names] is self-describing about the surface the
     table does not cover. Absent [--overrides] the trailer is suppressed, so an
     override-less adopter's output is byte-identical. *)
  if overrides_active then
    Printf.printf
      "\noverridden entries: %d (hand-written prose, renderings not recorded)\n"
      (List.length (List.filter (fun (_, s) -> s.overridden) results))

(* --- Message census --- *)

(* Normalize a message body for the census: collapse the state-specific depth in
   a delimiter hint ([<3>This '(' …] -> [<_>…]) and in a hedge-subject marker
   ([<^1>this expression] -> [<^_>…]) so identical wordings at different stack
   depths count as one census line and a depth shift does not churn the counts.
   The [^] kind tag is preserved, keeping the two marker families distinct in the
   census. Kept verbatim, the depth would fragment one wording into several
   census entries. *)
let census_normalize body =
  Str.global_replace (Str.regexp "<\\(\\^?\\)[0-9]+>") "<\\1_>" body

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

(* Print a ready-to-paste [.overrides] template block for every generic-fallback
   entry that is not yet overridden — the "Syntax error" states: the state's
   auto-generated ## comments (valid comment lines in the overrides format), the
   over-cap candidate list, the sentence key, and a placeholder message. Empty
   output means every fallback state is covered, the condition the stats
   ratchet pins at zero. *)
let output_fallbacks results =
  let header e =
    e.Parse_messages.entry_point ^ ": " ^ e.Parse_messages.sentence
  in
  let fallbacks =
    results
    |> List.filter (fun (_, stat) ->
        stat.empty_expected || stat.overflow_expected)
    |> List.sort (fun (e1, _) (e2, _) -> String.compare (header e1) (header e2))
  in
  Printf.eprintf "%d fallback state(s) without an override\n"
    (List.length fallbacks);
  List.iter
    (fun (entry, stat) ->
      List.iter print_endline entry.Parse_messages.original_comments;
      Printf.printf "# Candidates (%d): %s\n"
        (List.length stat.fallback_symbols)
        (String.concat ", " stat.fallback_symbols);
      Printf.printf "%s\n<YOUR SYNTAX ERROR MESSAGE HERE>\n\n" (header entry))
    fallbacks

(* Discovery aid: propose new [class] blocks for the [-config] file by
   signature-clustering the raw expected sets. A terminal's *signature* is the
   set of entries whose raw expected list mentions it; terminals with the
   *identical* signature always co-occur, so collapsing them to one label never
   drops a token a single state needed. Terminals already in a configured class
   are excluded (they are handled); nothing else is filtered. An earlier draft
   also dropped short punctuation aliases to avoid a "delimiter" cluster, but the
   operator tokens a class most wants to capture ([PLUS]="+", [STAR]="*") have
   one-character aliases too, so that filter excluded exactly them and broke the
   rediscovery. The identical-signature requirement is a strong enough guard on
   its own: distinct delimiters (')' / ',' / '}') appear in *varied* subsets
   across states, so they rarely share an exact signature and do not cluster. A
   cluster is kept only at >=3 members; ranked by impact — how
   many entries the collapse newly fits under the <=5 readable cap, then the
   total list-item reduction. Output is a paste-ready [class <LABEL>] block per
   cluster (label is a human decision, left as a placeholder), impact as [#]
   comments, in the [-list-fallbacks] authoring-template style. Empty output
   means no unclassified terminal set co-occurs tightly enough to be worth a
   class. *)
let output_suggest_classes cfg results =
  let classified =
    List.fold_left
      (fun acc (_, m) -> StringSet.union acc m)
      StringSet.empty cfg.classes
  in
  (* A candidate terminal: any terminal not already in a configured class. No
     alias-length filter: the operator tokens a class most wants to capture
     ([PLUS]="+", [STAR]="*") have one-character aliases, so filtering short
     aliases would exclude exactly them. The identical-signature requirement is
     itself the delimiter guard — ')' and ',' and '}' appear in *varied* subsets
     across states, so they rarely share an exact signature and do not cluster. *)
  let is_candidate t = not (StringSet.mem t classified) in
  let stats = Array.of_list (List.map snd results) in
  (* signature per candidate terminal: the set of entry indices mentioning it *)
  let sig_tbl = Hashtbl.create 256 in
  Array.iteri
    (fun i stat ->
      List.iter
        (fun t ->
          if is_candidate t then
            let r =
              match Hashtbl.find_opt sig_tbl t with
              | Some r -> r
              | None ->
                  let r = ref IntSet.empty in
                  Hashtbl.add sig_tbl t r;
                  r
            in
            r := IntSet.add i !r)
        stat.raw_terminals)
    stats;
  (* group terminals by identical signature *)
  let by_sig = Hashtbl.create 64 in
  Hashtbl.iter
    (fun t r ->
      let key = IntSet.elements !r in
      if key <> [] then
        let members =
          match Hashtbl.find_opt by_sig key with
          | Some m -> m
          | None ->
              let m = ref [] in
              Hashtbl.add by_sig key m;
              m
        in
        members := t :: !members)
    sig_tbl;
  (* each kept cluster with its impact simulation *)
  let clusters =
    Hashtbl.fold
      (fun entry_ids members acc ->
        let members = List.sort String.compare !members in
        let k = List.length members in
        if k < 3 then acc
        else
          (* every affected entry contains all k members (identical signature),
             so collapsing them removes k-1 items from that entry's list *)
          let newly_fits, reduction =
            List.fold_left
              (fun (nf, red) idx ->
                let len = stats.(idx).readable_len in
                let new_len = len - (k - 1) in
                ((if len > 5 && new_len <= 5 then nf + 1 else nf), red + (k - 1)))
              (0, 0) entry_ids
          in
          (members, k, List.length entry_ids, newly_fits, reduction) :: acc)
      by_sig []
  in
  (* rank by impact: newly-fitting entries, then total reduction, then size *)
  let ranked =
    List.sort
      (fun (m1, k1, _, nf1, r1) (m2, k2, _, nf2, r2) ->
        if nf1 <> nf2 then compare nf2 nf1
        else if r1 <> r2 then compare r2 r1
        else if k1 <> k2 then compare k2 k1
        else compare m1 m2)
      clusters
  in
  Printf.eprintf "%d candidate class cluster(s) (>=3 co-occurring terminals)\n"
    (List.length ranked);
  List.iter
    (fun (members, k, states, newly_fits, reduction) ->
      Printf.printf
        "# cluster of %d tokens co-occurring in %d state(s); collapsing them\n"
        k states;
      Printf.printf
        "# newly fits %d entrie(s) under the <=5 cap and removes %d list \
         item(s).\n"
        newly_fits reduction;
      Printf.printf "[class <LABEL>]\n";
      List.iter print_endline members;
      print_newline ())
    ranked

(* --- Main Entry Point --- *)

(* The output mode, one per subcommand. [Generate] carries the [--no-comments]
   flag; every other mode is a nullary tag. *)
type mode =
  | Generate of bool  (** [true] = [--no-comments] *)
  | Stats
  | Census
  | Names
  | Fallbacks
  | Suggest_classes
  | Transitions

(* Run one mode over the [.messages] file, given the three grammar sidecars
   ([config_file]/[overrides_file] are [""] when not supplied). Every mode
   parses the entries, checks override rot, loads the [.cmly] grammar (and the
   config, checking its rot too), then dispatches on [mode]. The rot guards
   raise [Failure], caught at the top level and rendered as a clean one-line
   error. *)
let run mode ~cmly_file ~config_file ~overrides_file input_file =
  let entries = Parse_messages.parse_file input_file in
  Printf.eprintf "Parsed %d entries from %s\n" (List.length entries) input_file;
  let overrides =
    if overrides_file = "" then StringMap.empty
    else load_overrides overrides_file
  in
  (* Rot protection: every override must still key a live error state, in every
     mode, so a stale entry can never sit silently in the file. *)
  check_override_rot overrides entries;
  let terminals, grammar0, auto = load_grammar cmly_file in
  let cfg =
    if config_file = "" then empty_config
    else
      let cfg = load_config config_file in
      (* Rot protection: every config entry must still name a live grammar
         symbol, in every config-consuming mode. *)
      check_config_rot ~file:config_file grammar0 cfg;
      cfg
  in
  let grammar = apply_wrapper_overrides cfg grammar0 in
  (* Closer terminals are derived from the token aliases, so a grammar that
     aliases its delimiters gets hints with no configuration. *)
  let closers = closers_of terminals in
  let mates = mates_of grammar terminals closers in
  match mode with
  | Transitions -> analyze_transitions closers mates grammar entries
  | Generate _ | Stats | Census | Names | Fallbacks | Suggest_classes -> (
      let comments = match mode with Generate nc -> not nc | _ -> true in
      (match mode with
      | Generate _ -> Printf.eprintf "Generating messages...\n"
      | _ -> ());
      let results =
        List.map
          (fun entry ->
            let text, body, stat =
              generate_message cfg closers mates grammar terminals ~comments
                ~overrides entry
            in
            (entry, (text, body, stat)))
          entries
      in
      let stats_of () =
        List.map (fun (entry, (_, _, stat)) -> (entry, stat)) results
      in
      match mode with
      | Generate no_comments ->
          (* The full [.messages] output (with comments) fed to
             [--compile-errors] keeps menhir's order; the stripped
             [--no-comments] golden is sorted by the sentence header
             ([entry_point: sentence]) so entry order stops tracking state
             numbers and a state merge becomes one clean local deletion instead
             of scattered delete+add pairs. *)
          let to_print =
            if no_comments then
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
          List.iter (fun (_, (text, _, _)) -> print_string text) to_print
      | Census ->
          output_census (List.map (fun (_, (_, body, _)) -> body) results)
      | Stats -> output_stats cfg grammar auto (stats_of ())
      | Names ->
          output_names ~overrides_active:(overrides_file <> "") cfg
            (stats_of ())
      | Fallbacks -> output_fallbacks (stats_of ())
      | Suggest_classes -> output_suggest_classes cfg (stats_of ())
      | Transitions -> assert false)

(* ============================================================================
   The %on_error_reduce annotation tuner (`stele tune`)
   ============================================================================

   A read-only advisor that automates, at the level the evidence supports, the
   hand A/B work of the annotation prune: it
   RECOMMENDS single [%on_error_reduce] moves; it NEVER applies them, and it
   NEVER touches the source tree — every trial runs against a *copy* of the
   grammar in a throwaway scratch dir (removed on exit, even on failure or
   Ctrl-C). It is wired into no runtest alias; the three promoted goldens already
   guard the committed state. Single-move scores DO NOT compose (the
   [list(index)]/[list(elemexpr)] interaction proved it): any applied *set* needs
   a fresh combined re-check.

   This is the in-process successor of the old [tune_on_error_reduce.sh]. Menhir
   is a runtime subprocess for this subcommand only (each trial re-runs
   [--list-errors] and [--cmly] on the mutated grammar copy). Everything else is
   in-process: the same [Parse_messages.parse_file], [load_grammar],
   [load_config], [generate_message]/[message_stat], and [load_overrides] key
   parser the other modes use — so a stats addition can never break a text-format
   coupling, and the override-rot column shares [check_override_rot]'s notion of
   an override key.

   THE NO-OVERRIDES TRIAL CONSTRAINT (important — read before changing this).
   A trial that changes the annotation list can merge/renumber automaton states,
   which makes [menhir --list-errors] re-pick its representative sentence per
   state. The step-5 [.overrides] files are keyed by sentence, so a re-picked
   sentence can fail the generator's hard rot check ([check_override_rot]) and
   kill the trial. Therefore EVERY generation here runs WITHOUT overrides
   ([~overrides:StringMap.empty]), baseline and trials alike; the ~52
   would-be-overridden states then sit uniformly on both sides of every
   comparison and the deltas stay meaningful. Consequence: the "over 5" fallback
   counter shows the raw pre-override figure (18 wasm / 34 wax), not the
   post-override 0 — expected and correct for A/B deltas.

   THE PIPELINE PER TRIAL: [menhir COPY.mly --list-errors] and [menhir COPY.mly
   --cmly --no-code-generation --base X] into the scratch dir, then the in-process
   generator against those two artifacts and the grammar's [.config] (the config
   carries the readable names/classes the goldens use, so a trial without it would
   diff spuriously). Candidate ADDITIONS are the nonterminals reduced somewhere in
   the automaton ([reducible_nonterminals], the SDK analogue of the LHS of every
   [reduce production] line in [menhir --dump]) minus the current list and the
   [__anonymous_*] internals.

   THE OVERRIDE-ROT COST. The trials run override-free, so a move's scored "win"
   is in the *generated* view only — it cannot see that the win merely relocates
   or re-keys a state the [.overrides] file already serves with a hand message.
   Every IMPROVING move is therefore also priced by its override-rot cost: the
   override keys ([--overrides]) that head an entry in the baseline no-comments
   projection but no longer head one in the trial. A move whose single improving
   signal (over-5/uncovered/template) has magnitude exactly equal to its rot is
   reclassified IMPROVING -> RELOCATES-OVERRIDDEN (neutral): the whole win lands
   on already-overridden states, a wash unless the merged message beats the hand
   override (a human call). A move with rot the win does not fully account for
   stays IMPROVING but is flagged prominently. Rot is priced only for IMPROVING
   moves, never for calibration, so the calibration agreement is untouched. *)

(* The stats vector consumed in-process (no output parsing). Each field is a
   plain count computed from the [message_stat] records and the soundness oracle,
   the exact quantities the old shell tuner scraped from [-stats] text. *)
type tune_vec = {
  tv_entries : int;
  tv_withlist : int;
  tv_template : int;
  tv_cascade : int;
  tv_empty : int;
  tv_over5 : int;
  tv_hints : int;
  tv_missed : int;
  tv_jargon : int;
  tv_unsound : int;
  tv_uncov_e : int;
  tv_uncov_t : int;
}

(* One evaluated grammar variant: its stats vector, its set of [entry_point:
   sentence] header keys (for override-rot), its sorted no-comments message
   projection and its census (both for the zero-diff DEAD test — the structured
   equivalents of the three promoted goldens). *)
type tune_trial = {
  tt_vec : tune_vec;
  tt_headers : StringSet.t;
  tt_actual : string list;
  tt_census : (string * int) list;
}

(* --- scratch + subprocess plumbing --- *)

let tune_read_file f = In_channel.with_open_bin f In_channel.input_all

let tune_write_file f s =
  Out_channel.with_open_bin f (fun oc -> Out_channel.output_string oc s)

let tune_rm_rf dir =
  if Sys.file_exists dir then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

(* Run [f] with a fresh scratch dir, guaranteed removed afterwards. [Fun.protect]
   covers a normal return or an exception (a bad grammar, a rot failure); the
   [at_exit] hook covers an uncaught exception that skips the [finally]; and the
   SIGINT handler turns Ctrl-C into a normal [exit], which runs [at_exit]. So the
   source tree is byte-identical after any run. *)
let tune_with_scratch f =
  let dir = Filename.temp_dir "stele-tune-" "" in
  at_exit (fun () -> tune_rm_rf dir);
  let prev = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> exit 130)) in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigint prev;
      tune_rm_rf dir)
    (fun () -> f dir)

(* Verify the menhir command actually runs; a clear failure otherwise (caught at
   the top level and printed as a one-line [stele:] error). *)
let tune_check_menhir menhir =
  let cmd =
    Printf.sprintf "%s --version >/dev/null 2>&1" (Filename.quote menhir)
  in
  if Sys.command cmd <> 0 then
    failwith
      (Printf.sprintf
         "menhir command %S is not executable (pass --menhir, or run under the \
          opam switch that provides menhir)"
         menhir)

(* Nonterminals reduced somewhere in the automaton — the SDK analogue of the LHS
   of every [reduce production ...] line [menhir --dump] prints, and so the same
   candidate universe the shell tuner enumerated. *)
let reducible_nonterminals cmly_file =
  let module G = MenhirSdk.Cmly_read.Read (struct
    let filename = cmly_file
  end) in
  let open G in
  let s = ref StringSet.empty in
  let add p = s := StringSet.add (Nonterminal.name (Production.lhs p)) !s in
  Lr1.iter (fun st ->
      (match Lr1.default_reduction st with Some p -> add p | None -> ());
      List.iter (fun (_, p) -> add p) (Lr1.get_reductions st));
  !s

(* The current [%on_error_reduce] list, and the grammar with that list replaced.
   One line per grammar (both wax and wasm carry exactly one). *)
let tune_oer_prefix = "%on_error_reduce "

let tune_current_annotations src =
  String.split_on_char '\n' src
  |> List.find_opt (fun l -> String.starts_with ~prefix:tune_oer_prefix l)
  |> function
  | None -> failwith "grammar has no %on_error_reduce declaration"
  | Some line ->
      String.sub line
        (String.length tune_oer_prefix)
        (String.length line - String.length tune_oer_prefix)
      |> String.split_on_char ' '
      |> List.filter (fun s -> String.trim s <> "")

let tune_replace_annotations src newlist =
  String.split_on_char '\n' src
  |> List.map (fun l ->
      if String.starts_with ~prefix:tune_oer_prefix l then
        tune_oer_prefix ^ String.concat " " newlist
      else l)
  |> String.concat "\n"

(* Run one grammar variant through menhir (subprocess) then the generator
   (in-process, override-free), returning its [tune_trial], or [None] when menhir
   rejected the mutated grammar (an invalid candidate name — the caller skips
   it). [mly] is the grammar file; [outprefix] names the scratch artifacts. *)
let tune_run_trial ~menhir ~config_file ~mly ~outprefix : tune_trial option =
  let q = Filename.quote in
  let messages = outprefix ^ ".messages" in
  let cmly = outprefix ^ ".cmly" in
  if
    Sys.command
      (Printf.sprintf "%s %s --list-errors > %s 2>/dev/null" (q menhir) (q mly)
         (q messages))
    <> 0
  then None
  else begin
    (* [--cmly] exits 1 (it also runs the code back-end, which dune's type
       inference would feed) but still writes the .cmly; check the file, not the
       exit code — exactly as the build rules and the old shell tuner do. *)
    ignore
      (Sys.command
         (Printf.sprintf
            "%s %s --cmly --no-code-generation --base %s >/dev/null 2>&1"
            (q menhir) (q mly) (q outprefix)));
    if not (Sys.file_exists cmly) then None
    else
      try
        let entries = Parse_messages.parse_file messages in
        let terminals, grammar0, auto = load_grammar cmly in
        let cfg =
          if config_file = "" then empty_config else load_config config_file
        in
        let grammar = apply_wrapper_overrides cfg grammar0 in
        let closers = closers_of terminals in
        let mates = mates_of grammar terminals closers in
        let results =
          List.map
            (fun entry ->
              let text, body, stat =
                generate_message cfg closers mates grammar terminals
                  ~comments:false ~overrides:StringMap.empty entry
              in
              (entry, text, body, stat))
            entries
        in
        let count f =
          List.length (List.filter (fun (_, _, _, s) -> f s) results)
        in
        let cascade =
          List.length
            (List.filter
               (fun (e, _, _, _) ->
                 List.length e.Parse_messages.data.spurious_reductions >= 4)
               results)
        in
        let missed =
          List.fold_left
            (fun a (_, _, _, s) -> a + List.length s.missed_hints)
            0 results
        in
        let jargon =
          List.fold_left
            (fun a (_, _, _, s) -> StringSet.union a s.jargon)
            StringSet.empty results
          |> StringSet.cardinal
        in
        let oracle =
          List.map (fun (e, _, _, s) -> check_entry grammar auto (e, s)) results
        in
        let unsound =
          List.fold_left (fun a (u, _) -> a + List.length u) 0 oracle
        in
        let uncov_e =
          List.length
            (List.filter (fun (_, unc) -> not (StringSet.is_empty unc)) oracle)
        in
        let uncov_t =
          List.fold_left (fun a (_, unc) -> a + StringSet.cardinal unc) 0 oracle
        in
        let vec =
          {
            tv_entries = List.length results;
            tv_withlist = count (fun s -> s.expecting);
            tv_template = count (fun s -> s.assuming);
            tv_cascade = cascade;
            tv_empty = count (fun s -> s.empty_expected);
            tv_over5 = count (fun s -> s.overflow_expected);
            tv_hints = count (fun s -> s.hinted);
            tv_missed = missed;
            tv_jargon = jargon;
            tv_unsound = unsound;
            tv_uncov_e = uncov_e;
            tv_uncov_t = uncov_t;
          }
        in
        let headers =
          List.fold_left
            (fun acc (e, _, _, _) ->
              StringSet.add
                (e.Parse_messages.entry_point ^ ": " ^ e.Parse_messages.sentence)
                acc)
            StringSet.empty results
        in
        let actual =
          List.map (fun (_, text, _, _) -> text) results
          |> List.sort String.compare
        in
        let ctbl = Hashtbl.create 256 in
        List.iter
          (fun (_, _, body, _) ->
            let k = census_normalize body in
            Hashtbl.replace ctbl k
              (1 + try Hashtbl.find ctbl k with Not_found -> 0))
          results;
        let census =
          Hashtbl.fold (fun m c acc -> (m, c) :: acc) ctbl []
          |> List.sort (fun (a, _) (b, _) -> String.compare a b)
        in
        Some
          {
            tt_vec = vec;
            tt_headers = headers;
            tt_actual = actual;
            tt_census = census;
          }
      with _ -> None
  end

(* A move's verdict, mirroring the shell tuner's classification model (matching
   the prune's decision rule); the string is the short reason shown in the report. *)
type tune_verdict =
  | THarmful of string
  | TImproving of string
  | TDead
  | TMixed of string
  | TNeutral of string

let tune_classify ~base ~trial =
  let b = base.tt_vec and t = trial.tt_vec in
  let d_over5 = t.tv_over5 - b.tv_over5
  and d_empty = t.tv_empty - b.tv_empty
  and d_hints = t.tv_hints - b.tv_hints
  and d_jargon = t.tv_jargon - b.tv_jargon
  and d_unsound = t.tv_unsound - b.tv_unsound
  and d_missed = t.tv_missed - b.tv_missed
  and d_uncov_e = t.tv_uncov_e - b.tv_uncov_e
  and d_uncov_t = t.tv_uncov_t - b.tv_uncov_t
  and d_template = t.tv_template - b.tv_template
  and d_cascade = t.tv_cascade - b.tv_cascade in
  if d_over5 > 0 then THarmful (Printf.sprintf "+%d over-5 fallback(s)" d_over5)
  else if d_empty > 0 then
    THarmful (Printf.sprintf "+%d empty-list fallback(s)" d_empty)
  else if d_hints < 0 then
    THarmful (Printf.sprintf "%d delimiter hint(s)" d_hints)
  else if d_jargon > 0 then
    THarmful (Printf.sprintf "+%d jargon token(s)" d_jargon)
  else if d_unsound > 0 then
    THarmful (Printf.sprintf "+%d unsound claim(s)" d_unsound)
  else if d_missed > 0 then
    THarmful (Printf.sprintf "+%d missed hint(s)" d_missed)
  else if d_uncov_e > 0 || d_uncov_t > 0 then
    THarmful
      (Printf.sprintf "+%d uncovered entries / +%d tokens" d_uncov_e d_uncov_t)
  else
    let why = Buffer.create 32 in
    if d_template < 0 then
      Buffer.add_string why (Printf.sprintf " template%d" d_template);
    if d_uncov_e < 0 then
      Buffer.add_string why (Printf.sprintf " uncov_e%d" d_uncov_e);
    if d_uncov_t < 0 then
      Buffer.add_string why (Printf.sprintf " uncov_t%d" d_uncov_t);
    if d_over5 < 0 then
      Buffer.add_string why (Printf.sprintf " over5%d" d_over5);
    if Buffer.length why > 0 then TImproving (String.trim (Buffer.contents why))
    else if
      base.tt_vec = trial.tt_vec
      && base.tt_actual = trial.tt_actual
      && base.tt_census = trial.tt_census
    then TDead
    else if (d_hints > 0 || d_cascade < 0) && d_template > 0 then
      let gain =
        match (d_hints > 0, d_cascade < 0) with
        | true, true ->
            Printf.sprintf
              "adds %d unclosed-delimiter pointer%s and removes %d deep \
               \"Assuming ...\" chain%s"
              d_hints
              (if d_hints = 1 then "" else "s")
              (-d_cascade)
              (if -d_cascade = 1 then "" else "s")
        | true, false ->
            Printf.sprintf "adds %d unclosed-delimiter pointer%s" d_hints
              (if d_hints = 1 then "" else "s")
        | false, _ ->
            Printf.sprintf "removes %d deep \"Assuming ...\" chain%s"
              (-d_cascade)
              (if -d_cascade = 1 then "" else "s")
      in
      TMixed
        (Printf.sprintf "%s but also adds %d new \"Assuming ...\" message%s"
           gain d_template
           (if d_template = 1 then "" else "s"))
    else
      TNeutral
        (Printf.sprintf "no quality movement (template%d hints+%d cascade%d)"
           d_template d_hints d_cascade)

(* The single mechanically-clear improving signal of a move (over-5 / uncovered /
   template) and its magnitude, or [None] when several signals mix (not
   attributable, so it stays IMPROVING and is only rot-flagged). *)
let tune_gain ~base ~trial =
  let b = base.tt_vec and t = trial.tt_vec in
  let d_over5 = t.tv_over5 - b.tv_over5
  and d_uncov_e = t.tv_uncov_e - b.tv_uncov_e
  and d_template = t.tv_template - b.tv_template in
  if d_over5 < 0 && d_uncov_e = 0 && d_template = 0 then
    Some ("over-5 fallback", -d_over5)
  else if d_uncov_e < 0 && d_over5 = 0 && d_template = 0 then
    Some ("uncovered action", -d_uncov_e)
  else if d_template < 0 && d_over5 = 0 && d_uncov_e = 0 then
    Some ("hedge template", -d_template)
  else None

(* The override-rot cost: the override keys (from [--overrides], parsed by the
   real [load_overrides]) that head an entry in the baseline projection but no
   longer head one in the trial's — sentences the trial's state merge/renumber
   made [--list-errors] drop or re-pick, on states the [.overrides] file serves. *)
let tune_compute_rot override_keys ~base ~trial =
  List.filter
    (fun k ->
      StringSet.mem k base.tt_headers && not (StringSet.mem k trial.tt_headers))
    override_keys

(* Spell a small count so a delta sentence can open with a capitalized word;
   larger counts (chiefly token totals) fall through to digits. *)
let tune_num_word n =
  match n with
  | 0 -> "zero"
  | 1 -> "one"
  | 2 -> "two"
  | 3 -> "three"
  | 4 -> "four"
  | 5 -> "five"
  | 6 -> "six"
  | 7 -> "seven"
  | 8 -> "eight"
  | 9 -> "nine"
  | 10 -> "ten"
  | _ -> string_of_int n

let tune_capitalize s =
  if s = "" then s
  else
    String.make 1 (Char.uppercase_ascii s.[0])
    ^ String.sub s 1 (String.length s - 1)

(* One clause naming a moved quality counter: e.g. "one fewer over-cap 'Syntax
   error' state". [d] is trial-minus-base; a decrease reads "fewer", an increase
   "more". *)
let tune_counter_clause d sing plur =
  let n = abs d in
  let dir = if d < 0 then "fewer" else "more" in
  Printf.sprintf "%s %s %s" (tune_num_word n) dir (if n = 1 then sing else plur)

(* The zero-suppressed delta: one plain sentence that names ONLY the counters a
   move shifted, in the stats goldens' vocabulary. An unmoved counter is silent
   (no zero-heavy vector); the two size counts (error states, states with an
   expected list) show their exact before/after when they moved. *)
let tune_vector_delta base trial =
  let b = base.tt_vec and t = trial.tt_vec in
  let clauses = ref [] in
  let add c = clauses := c :: !clauses in
  let counter d sing plur =
    if d <> 0 then add (tune_counter_clause d sing plur)
  in
  counter (t.tv_over5 - b.tv_over5) "over-cap \"Syntax error\" state"
    "over-cap \"Syntax error\" states";
  counter (t.tv_empty - b.tv_empty) "empty-list \"Syntax error\" state"
    "empty-list \"Syntax error\" states";
  counter (t.tv_hints - b.tv_hints) "unclosed-delimiter pointer"
    "unclosed-delimiter pointers";
  counter
    (t.tv_template - b.tv_template)
    "\"Assuming ...\" message" "\"Assuming ...\" messages";
  counter
    (t.tv_cascade - b.tv_cascade)
    "deep \"Assuming ...\" chain (depth >= 4)"
    "deep \"Assuming ...\" chains (depth >= 4)";
  (let d_e = t.tv_uncov_e - b.tv_uncov_e
   and d_t = t.tv_uncov_t - b.tv_uncov_t in
   if d_e <> 0 then
     let head =
       tune_counter_clause d_e "state with uncovered actions"
         "states with uncovered actions"
     in
     if d_t <> 0 then
       add
         (Printf.sprintf "%s (%d %s token%s)" head (abs d_t)
            (if d_t < 0 then "fewer" else "more")
            (if abs d_t = 1 then "" else "s"))
     else add head
   else if d_t <> 0 then
     add
       (Printf.sprintf "%d %s uncovered-action token%s" (abs d_t)
          (if d_t < 0 then "fewer" else "more")
          (if abs d_t = 1 then "" else "s")));
  counter
    (t.tv_jargon - b.tv_jargon)
    "jargon-rendered token" "jargon-rendered tokens";
  counter (t.tv_unsound - b.tv_unsound) "unsound claim" "unsound claims";
  if t.tv_entries <> b.tv_entries then
    add
      (Printf.sprintf "error states %d \xe2\x86\x92 %d" b.tv_entries
         t.tv_entries);
  if t.tv_withlist <> b.tv_withlist then
    add
      (Printf.sprintf "states with an expected list %d \xe2\x86\x92 %d"
         b.tv_withlist t.tv_withlist);
  match List.rev !clauses with
  | [] -> "    No counted change."
  | clauses -> "    " ^ tune_capitalize (String.concat "; " clauses) ^ "."

(* A census diff (baseline vs trial), keyed by normalized body: one [-]/[+] pair
   per body whose count changed, sorted by body. The structured mirror of the
   old shell tuner's [diff] over the census golden. *)
let tune_census_diff base trial =
  let bm =
    List.fold_left
      (fun m (k, v) -> StringMap.add k v m)
      StringMap.empty base.tt_census
  in
  let tm =
    List.fold_left
      (fun m (k, v) -> StringMap.add k v m)
      StringMap.empty trial.tt_census
  in
  let keys =
    StringSet.union
      (StringSet.of_list (List.map fst base.tt_census))
      (StringSet.of_list (List.map fst trial.tt_census))
  in
  let render sign body count =
    match String.split_on_char '\n' body with
    | [] -> ""
    | first :: rest ->
        let head = Printf.sprintf "      %s %5dx %s" sign count first in
        String.concat "\n"
          (head :: List.map (fun l -> Printf.sprintf "               %s" l) rest)
  in
  StringSet.elements keys
  |> List.filter_map (fun k ->
      let bc = try StringMap.find k bm with Not_found -> 0 in
      let tc = try StringMap.find k tm with Not_found -> 0 in
      if bc = tc then None
      else
        let lines =
          (if bc > 0 then [ render "-" k bc ] else [])
          @ if tc > 0 then [ render "+" k tc ] else []
        in
        Some (String.concat "\n" lines))
  |> String.concat "\n"

(* Read the current annotations and the (optional) override keys off a grammar,
   copy it into scratch, and compute the override-free baseline. *)
type tune_setup = {
  ts_src : string;
  ts_annots : string list;
  ts_mly : string;  (** the scratch grammar copy, mutated per trial *)
  ts_config : string;
  ts_menhir : string;
  ts_base : tune_trial;
  ts_override_keys : string list;
  ts_base_cmly : string;
}

let tune_setup ~menhir ~config_file ~overrides_file ~grammar_file ~scratch =
  let src = tune_read_file grammar_file in
  let annots = tune_current_annotations src in
  let mly = Filename.concat scratch "parser.mly" in
  tune_write_file mly src;
  let base_prefix = Filename.concat scratch "base" in
  let base =
    match tune_run_trial ~menhir ~config_file ~mly ~outprefix:base_prefix with
    | Some t -> t
    | None ->
        failwith
          "baseline pipeline failed (menhir could not process the grammar)"
  in
  let override_keys =
    if overrides_file = "" then []
    else
      StringMap.fold
        (fun k _ acc -> k :: acc)
        (load_overrides overrides_file)
        []
  in
  {
    ts_src = src;
    ts_annots = annots;
    ts_mly = mly;
    ts_config = config_file;
    ts_menhir = menhir;
    ts_base = base;
    ts_override_keys = override_keys;
    ts_base_cmly = base_prefix ^ ".cmly";
  }

(* Build the trial grammar for a move and evaluate it. [op] is `Remove or `Add. *)
let tune_move ts op nt =
  let newlist =
    match op with
    | `Remove -> List.filter (fun a -> a <> nt) ts.ts_annots
    | `Add -> ts.ts_annots @ [ nt ]
  in
  tune_write_file ts.ts_mly (tune_replace_annotations ts.ts_src newlist);
  tune_run_trial ~menhir:ts.ts_menhir ~config_file:ts.ts_config ~mly:ts.ts_mly
    ~outprefix:(Filename.concat (Filename.dirname ts.ts_mly) "trial")

(* --- the three report parts --- *)

(* Plain phrasing shared by the improving-collateral and relocates sections:
   the N hand-written messages (from the [.overrides] file) whose key sentences
   the trial's state merge/renumber changes. *)
let tune_rekey_phrase rc =
  if rc = 1 then "1 hand-written message (its key sentence changes)"
  else Printf.sprintf "%d hand-written messages (their key sentences change)" rc

let tune_dead_sweep ts =
  Printf.printf
    "### DEAD SWEEP — remove each current annotation; a removal that changes \
     nothing is dead\n";
  let dead =
    List.fold_left
      (fun n nt ->
        match tune_move ts `Remove nt with
        | None ->
            Printf.printf
              "  (skip: removing %s makes menhir reject the grammar)\n" nt;
            n
        | Some trial ->
            if tune_classify ~base:ts.ts_base ~trial = TDead then begin
              Printf.printf
                "  ---- remove %s\n\
                \    DEAD: message text, census, and stats are all unchanged; \
                 safe to delete\n"
                nt;
              n + 1
            end
            else n)
      0 ts.ts_annots
  in
  Printf.printf "  dead annotations found: %d\n\n" dead

let tune_advisor ts candidates =
  Printf.printf
    "### ADVISOR — single-move ranking (%d removals, %d additions)\n"
    (List.length ts.ts_annots) (List.length candidates);
  let improving = ref [] and relocates = ref [] and mixed = ref [] in
  let harmful = ref 0
  and neutral = ref 0
  and dead = ref 0
  and skipped = ref 0 in
  let do_move op nt =
    match tune_move ts op nt with
    | None -> incr skipped
    | Some trial -> (
        let label =
          (match op with `Remove -> "remove " | `Add -> "add ") ^ nt
        in
        match tune_classify ~base:ts.ts_base ~trial with
        | THarmful _ -> incr harmful
        | TDead -> incr dead
        | TNeutral _ -> incr neutral
        | TMixed reason -> mixed := (label, reason) :: !mixed
        | TImproving reason -> (
            let rot =
              tune_compute_rot ts.ts_override_keys ~base:ts.ts_base ~trial
            in
            let rc = List.length rot in
            let gain = tune_gain ~base:ts.ts_base ~trial in
            let vec = tune_vector_delta ts.ts_base trial in
            match gain with
            | Some (gk, gn) when rc > 0 && gn > 0 && rc = gn ->
                relocates := (label, gk, rc, rot, vec) :: !relocates
            | _ ->
                let cen = tune_census_diff ts.ts_base trial in
                improving := (label, reason, rc, rot, vec, cen) :: !improving))
  in
  List.iter (fun nt -> do_move `Remove nt) ts.ts_annots;
  List.iter (fun nt -> do_move `Add nt) candidates;
  let improving = List.rev !improving
  and relocates = List.rev !relocates
  and mixed = List.rev !mixed in
  Printf.printf
    "  summary: improving=%d relocates-overridden=%d mixed=%d harmful=%d \
     dead/no-op=%d neutral=%d skipped=%d\n"
    (List.length improving) (List.length relocates) (List.length mixed) !harmful
    !dead !neutral !skipped;
  Printf.printf
    "  legend:\n\
    \    improving            a single move that improves a quality counter \
     with no regression\n\
    \    relocates-overridden the whole improvement lands only on states that \
     carry a hand-written message\n\
    \    mixed                gains an unclosed-delimiter pointer but also \
     adds a new \"Assuming ...\" message\n\
    \    harmful              regresses a quality counter (a fallback, a lost \
     pointer, a jargon token, an unsound claim)\n\
    \    dead/no-op           leaves every counter, message, and census body \
     unchanged\n\
    \    neutral              counters shift but net quality is unchanged\n\
    \    skipped              menhir rejected the mutated grammar\n\n";
  if improving = [] then
    Printf.printf
      "  No strictly-improving single move (expected right after a prune).\n"
  else begin
    Printf.printf
      "  IMPROVING MOVES — each improves a quality counter (review \
       individually; scores do not compose):\n";
    List.iter
      (fun (label, _reason, rc, rot, vec, cen) ->
        Printf.printf "  ---- %s\n%s\n" label vec;
        if rc > 0 then begin
          Printf.printf
            "    Also re-keys %s;\n\
            \    the win does not fully account for them, so confirm the \
             merged message still beats each:\n"
            (tune_rekey_phrase rc);
          List.iter (fun k -> Printf.printf "      %s\n" k) rot
        end;
        Printf.printf "    message-wording changes (census diff):\n%s\n" cen)
      improving
  end;
  Printf.printf "\n";
  if relocates <> [] then begin
    Printf.printf
      "  RELOCATES-OVERRIDDEN — the whole improvement lands on states that \
       already\n\
      \  carry a hand-written message, so the move merely relocates them. \
       Apply only\n\
      \  if the generated message would beat the hand-written one, not for the \
       counter\n\
      \  delta alone:\n";
    List.iter
      (fun (label, _gk, rc, rot, vec) ->
        Printf.printf "  ---- %s\n%s\n" label vec;
        Printf.printf "    Re-keys %s:\n" (tune_rekey_phrase rc);
        List.iter (fun k -> Printf.printf "      %s\n" k) rot)
      relocates;
    Printf.printf "\n"
  end;
  if mixed <> [] then begin
    Printf.printf
      "  MIXED — needs a human eye: the move gains an unclosed-delimiter \
       pointer but\n\
      \  also adds a new \"Assuming ...\" message. Read the census diff and \
       decide:\n";
    List.iter
      (fun (label, reason) -> Printf.printf "  ---- %s\n    %s\n" label reason)
      mixed;
    Printf.printf "\n"
  end

(* Parse a verdicts file: lines [keep NT] / [removed NT], [#] comments and blanks
   ignored. Returns (kept, removed). *)
let tune_parse_verdicts file =
  Parse_messages.read_lines file
  |> List.fold_left
       (fun (kept, removed) line ->
         let t = String.trim line in
         if t = "" || t.[0] = '#' then (kept, removed)
         else
           match String.index_opt t ' ' with
           | None ->
               failwith (Printf.sprintf "verdicts: malformed line %S" line)
           | Some i -> (
               let verb = String.sub t 0 i in
               let nt = String.trim (String.sub t i (String.length t - i)) in
               if nt = "" then
                 failwith (Printf.sprintf "verdicts: malformed line %S" line);
               match verb with
               | "keep" -> (nt :: kept, removed)
               | "removed" -> (kept, nt :: removed)
               | _ ->
                   failwith
                     (Printf.sprintf
                        "verdicts: unknown verb %S (expected 'keep' or \
                         'removed')"
                        verb)))
       ([], [])
  |> fun (kept, removed) -> (List.rev kept, List.rev removed)

(* Replay a recorded keep/remove log: removing a KEPT annotation and re-adding a
   REMOVED one should each be non-improving. Reports the agreement fraction and
   every disagreement — the deliverable of this part. *)
let tune_calibrate ts ~kept ~removed =
  Printf.printf
    "### CALIBRATION — replay the recorded keep/remove decisions\n\
    \  (removing a kept annotation, or re-adding a removed one, must score \
     non-improving)\n";
  let agree = ref 0 and total = ref 0 and disagree = ref [] in
  let is_improving = function TImproving _ -> true | _ -> false in
  List.iter
    (fun nt ->
      match tune_move ts `Remove nt with
      | None -> () (* menhir failure on removing a listed annotation is inert *)
      | Some trial ->
          incr total;
          if is_improving (tune_classify ~base:ts.ts_base ~trial) then
            disagree :=
              Printf.sprintf
                "kept %s, but removing it now scores as an improvement" nt
              :: !disagree
          else incr agree)
    kept;
  List.iter
    (fun nt ->
      match tune_move ts `Add nt with
      | None ->
          incr total;
          disagree :=
            Printf.sprintf
              "removed %s, but menhir now rejects re-adding it (stale name?)" nt
            :: !disagree
      | Some trial ->
          incr total;
          if is_improving (tune_classify ~base:ts.ts_base ~trial) then
            disagree :=
              Printf.sprintf
                "removed %s, but re-adding it now scores as an improvement" nt
              :: !disagree
          else incr agree)
    removed;
  Printf.printf "  agreement: %d / %d\n" !agree !total;
  if !disagree <> [] then begin
    Printf.printf "  disagreements:\n";
    List.iter (fun d -> Printf.printf "    %s\n" d) (List.rev !disagree)
  end;
  Printf.printf "\n"

type tune_mode = Tune_dead | Tune_advise | Tune_calibrate of string

let run_tune mode ~menhir ~config_file ~overrides_file ~grammar_file =
  tune_check_menhir menhir;
  let start = Unix.gettimeofday () in
  tune_with_scratch (fun scratch ->
      let ts =
        tune_setup ~menhir ~config_file ~overrides_file ~grammar_file ~scratch
      in
      Printf.printf "grammar: %s\n" grammar_file;
      Printf.printf "current %%on_error_reduce (%d): %s\n\n"
        (List.length ts.ts_annots)
        (String.concat " " ts.ts_annots);
      (match mode with
      | Tune_dead -> tune_dead_sweep ts
      | Tune_advise ->
          let candidates =
            reducible_nonterminals ts.ts_base_cmly
            |> StringSet.elements
            |> List.filter (fun nt ->
                (not (involves_anonymous nt)) && not (List.mem nt ts.ts_annots))
          in
          tune_advisor ts candidates
      | Tune_calibrate verdicts_file ->
          let kept, removed = tune_parse_verdicts verdicts_file in
          tune_calibrate ts ~kept ~removed);
      Printf.printf "sweep runtime: %.0fs\n" (Unix.gettimeofday () -. start))

(* --- Command-line interface (cmdliner) --- *)

open Cmdliner
open Term.Syntax

(* The three shared grammar sidecars and the positional [.messages] file, common
   to every subcommand. *)
let cmly_arg =
  let doc =
    "Path to the grammar's $(b,.cmly) file (produced by $(b,menhir --cmly)): \
     the source of exact productions, nullability, and token aliases. Required \
     by every command."
  in
  Arg.(required & opt (some string) None & info [ "cmly" ] ~docv:"FILE" ~doc)

let config_arg =
  let doc =
    "Path to the grammar's $(b,.config) sidecar: readable names, token \
     classes, and opener-name nets. Optional; absent means no curated names, \
     no classes, and alias-only delimiter hints."
  in
  Arg.(value & opt string "" & info [ "config" ] ~docv:"FILE" ~doc)

let overrides_arg =
  let doc =
    "Path to the grammar's hand-written $(b,.overrides) file: sentence-keyed \
     replacement messages for the states heuristics cannot serve, merged after \
     generation. An override whose sentence matches no error state fails the \
     build. Optional."
  in
  Arg.(value & opt string "" & info [ "overrides" ] ~docv:"FILE" ~doc)

let messages_arg =
  let doc =
    "The grammar's $(b,menhir --list-errors) output: one representative error \
     sentence per error state."
  in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"MESSAGES" ~doc)

let no_comments_arg =
  let doc =
    "Omit the auto-generated $(b,##) comments (state numbers, LR items), \
     keeping only the sentence and message, and sort the output by sentence — \
     the stable golden projection."
  in
  Arg.(value & flag & info [ "no-comments" ] ~doc)

let generate_cmd =
  let doc = "Generate the error messages (one per error state)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Emit a syntax-error message for every error state in the \
         $(i,MESSAGES) file: an $(b,Expecting) list of the legal \
         continuations, a delimiter hint, and an $(b,Assuming ... complete) \
         hedge where a reduction folded, with any hand overrides merged in. \
         This is the output that $(b,menhir --compile-errors) turns into a \
         $(b,Parser_messages) module.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ no_comments = no_comments_arg
    and+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run (Generate no_comments) ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "generate" ~doc ~man) term

let stats_cmd =
  let doc = "Print the message-quality summary and self-lints" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print the quality counters (entries, states with an expected list, \
         fallbacks split by whether an override covers them, delimiter hints, \
         missed hints, jargon, cascade depth) and the soundness-oracle lines, \
         plus one dormancy line per configured token class. This is the \
         ratchet: pin it as a golden and a regression fails the build.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Stats ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "stats" ~doc ~man) term

let census_cmd =
  let doc = "Print the distinct message bodies with occurrence counts" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print each distinct message body once, prefixed by its occurrence \
         count and sorted by message text (no sentences appear); the \
         delimiter-hint depth is normalized to $(b,<_>). A wording change is a \
         one-line diff; a sentence re-pick only bumps a count.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Census ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "census" ~doc ~man) term

let names_cmd =
  let doc =
    "Review how every symbol is rendered, and find unused config names"
  in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print a table of every grammar symbol that surfaces in the emitted \
         messages: its rendered form, the pipeline step that produced it \
         (token alias, $(b,[names]) entry, the list-element chase, the \
         Assuming-subject plural rendering, the lowercase auto-derivation, a \
         $(b,[class]) label, or the quoted-lowercase fallback), and how often \
         it appears in the Expecting list versus the Assuming subject. Usage \
         is counted per position because a symbol can render differently in \
         each. After the table, list any $(b,[names]) entries whose curated \
         phrase won in neither position. The audit surface for two directions: \
         awkward renderings that deserve a $(b,[names]) entry, and \
         $(b,[names]) entries nothing uses.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Names ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "names" ~doc ~man) term

let fallbacks_cmd =
  let doc = "Print .overrides templates for uncovered fallback states" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print a ready-to-paste $(b,.overrides) block for every \
         generic-fallback (\"Syntax error\") state not yet covered by an \
         override: the state's $(b,##) comments, the over-cap candidate list, \
         and the sentence key. Empty output means every fallback is covered.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Fallbacks ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "fallbacks" ~doc ~man) term

let suggest_classes_cmd =
  let doc = "Propose token-class blocks for the config" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Propose new $(b,[class]) blocks for the $(b,--config) file by \
         signature-clustering the raw expected sets: unclassed terminals that \
         always co-occur, kept at three or more members, ranked by how many \
         entries the collapse newly fits under the readable cap. Empty output \
         means nothing co-occurs tightly enough to be worth a class.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Suggest_classes ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "suggest-classes" ~doc ~man) term

let transitions_cmd =
  let doc = "List every continuation of each error state (debug)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "List, per error state, all possible continuation symbols with \
         lookahead and delimiter-depth annotations — a debugging view of the \
         raw continuation computation.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Transitions ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "transitions" ~doc ~man) term

(* The [tune] subcommand group. Unlike the other modes it does not take
   a prepared [--cmly]/[MESSAGES] pair — it generates those itself, per trial,
   from [--grammar] via a [--menhir] subprocess, in a scratch dir. *)
let grammar_arg =
  let doc =
    "Path to the grammar's $(b,.mly) source. The tuner copies it into a \
     scratch directory and edits the $(b,%on_error_reduce) line for each \
     trial; the source tree is never touched. One grammar per invocation."
  in
  Arg.(required & opt (some string) None & info [ "grammar" ] ~docv:"FILE" ~doc)

let menhir_arg =
  let doc =
    "The $(b,menhir) command to run for each trial (a runtime subprocess: \
     $(b,--list-errors) and $(b,--cmly)). A clear error is reported if it is \
     not executable."
  in
  Arg.(value & opt string "menhir" & info [ "menhir" ] ~docv:"CMD" ~doc)

let verdicts_arg =
  let doc =
    "Path to a recorded keep/remove log: lines $(b,keep NONTERMINAL) / \
     $(b,removed NONTERMINAL) ($(b,#) comments and blanks ignored). Removing a \
     $(b,keep) annotation and re-adding a $(b,removed) one must each score \
     non-improving; the command reports the agreement fraction and every \
     disagreement."
  in
  Arg.(
    required & opt (some string) None & info [ "verdicts" ] ~docv:"FILE" ~doc)

let tune_dead_cmd =
  let doc = "Find %on_error_reduce annotations whose removal changes nothing" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Remove each current $(b,%on_error_reduce) annotation in turn and \
         regenerate; an annotation whose removal leaves the stats, census, and \
         message projection all unchanged is dead and reported for deletion. \
         Trials run override-free (an annotation change re-picks the \
         sentence-keyed overrides), so nothing but the annotation moves.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ menhir = menhir_arg in
    run_tune Tune_dead ~menhir ~config_file:config ~overrides_file:overrides
      ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "dead" ~doc ~man) term

let tune_advise_cmd =
  let doc = "Rank single add/remove moves by their stats-vector delta" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "For each single move — removing a current annotation, or adding one \
         for a nonterminal reduced somewhere in the automaton — compute the \
         stats-vector delta and classify it (harmful / improving / dead / \
         mixed / neutral), matching the prune audit's decision rule. Each \
         improving move is priced by its $(b,override-rot) cost (the \
         $(b,--overrides) keys the trial's state re-pick would strand); a move \
         whose whole win lands on already-overridden states is reported \
         separately as $(b,RELOCATES-OVERRIDDEN). The tuner recommends; it \
         never applies, and single-move scores do not compose.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ menhir = menhir_arg in
    run_tune Tune_advise ~menhir ~config_file:config ~overrides_file:overrides
      ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "advise" ~doc ~man) term

let tune_calibrate_cmd =
  let doc = "Replay a recorded keep/remove log and report agreement" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Replay a recorded keep/remove verdict log ($(b,--verdicts)): removing \
         each $(b,keep) annotation and re-adding each $(b,removed) one should \
         score non-improving. Report the agreement fraction and every \
         disagreement — the way to confirm the classifier still reproduces a \
         trusted human audit after the grammar or the stats have changed.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ menhir = menhir_arg
    and+ verdicts = verdicts_arg in
    run_tune (Tune_calibrate verdicts) ~menhir ~config_file:config
      ~overrides_file:overrides ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "calibrate" ~doc ~man) term

let tune_cmd =
  let doc = "Advise on %on_error_reduce annotation moves (read-only)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "A read-only advisor for a grammar's $(b,%on_error_reduce) list. Each \
         trial re-runs $(b,menhir) (a subprocess) on a scratch copy of the \
         grammar with one annotation added or removed, regenerates the \
         messages in-process, and classifies the move by its effect on the \
         quality counters. It recommends moves; it never applies them and \
         never touches the source tree.";
      `P
        "Trials run WITHOUT the $(b,.overrides) file: an annotation change \
         re-picks the sentence-keyed overrides, so a trial that loaded them \
         could fail the rot guard. The overrides are still read (via \
         $(b,--overrides)) to price each improving move's override-rot cost.";
      `S Manpage.s_commands;
    ]
  in
  Cmd.group
    (Cmd.info "tune" ~doc ~man)
    [ tune_dead_cmd; tune_advise_cmd; tune_calibrate_cmd ]

let main_cmd =
  let doc = "User-friendly syntax-error messages for a Menhir grammar" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "stele turns a Menhir grammar's $(b,--list-errors) output and its \
         $(b,.cmly) into readable syntax-error messages, guarded by promoted \
         golden files so a grammar change shows up as a reviewable message \
         diff rather than silent staleness.";
      `P
        "Every command reads the same inputs: the $(b,--cmly) grammar \
         (required), an optional $(b,--config) sidecar, an optional \
         $(b,--overrides) file, and the positional $(i,MESSAGES) file (the \
         $(b,menhir --list-errors) output).";
      `S Manpage.s_commands;
      `S Manpage.s_examples;
      `P "Generate the messages for $(b,menhir --compile-errors):";
      `Pre
        "  $(mname) generate --cmly g.cmly --config g.config --overrides \
         g.overrides g.messages";
      `P "Print the quality ratchet:";
      `Pre "  $(mname) stats --cmly g.cmly --config g.config g.messages";
    ]
  in
  Cmd.group
    (Cmd.info "stele" ~doc ~man)
    [
      generate_cmd;
      stats_cmd;
      census_cmd;
      names_cmd;
      fallbacks_cmd;
      suggest_classes_cmd;
      transitions_cmd;
      tune_cmd;
    ]

(* A stale-sidecar rot guard (config or overrides) raises [Failure]; render it
   as a clean one-line error and exit non-zero, rather than letting it escape as
   an uncaught-exception backtrace. [~catch:false] keeps cmdliner from turning it
   into a generic internal error. *)
let () =
  let code =
    try Cmd.eval ~catch:false main_cmd
    with Failure msg ->
      Printf.eprintf "stele: %s\n" msg;
      1
  in
  exit code
