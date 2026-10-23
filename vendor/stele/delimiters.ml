open Util
open Grammar
open Config

(* --- Depth Calculation --- *)

(* Standard bracket pairing: the opening-delimiter character a closing one
   terminates. Grammar-agnostic (plain ASCII brackets), so it stays built in. *)
let opener_of_closer_char = function
  | ')' -> Some '('
  | ']' -> Some '['
  | '}' -> Some '{'
  | _ -> None

(* Derive the closer terminals from the grammar's token aliases (the mirror of
   the opener rule): any terminal whose alias ENDS with a closing-delimiter
   character, paired with the matching opener character — so a multi-character
   closer like [|]] ('|]') is recognised just as a compound opener like [(then]
   is by its first character. A grammar that aliases its delimiters gets hints
   with no configuration; one that does not simply gets none. Sorted for a
   deterministic tie-break order between closers valid in the same state. *)
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

(* EXACT opener<->closer pairs derived from the grammar's productions,
   not guessed from the shared bracket kind. In each production's right-hand
   side, a closer-classified symbol mates the nearest still-open
   opener-classified symbol of the SAME bracket character (proper nesting within
   the rhs — a stack pop); collected over every production. The result maps each
   closer token to the SET of opener tokens that mate it (a set because an opener
   may reach the same closer through several productions; a closer may have
   several distinct opener mates, e.g. in a WebAssembly text grammar ')' pairs
   with '(', '(then', '(param', …). This is what lets [find_matching_depth] balance per exact pair
   so a plain '[' and a compound '[|' that share the '[' kind stop cross-matching.

   Ambiguity: the nearest-following-closer-of-the-same-kind rule gives each
   opener occurrence exactly one mate per production, so a production is never
   ambiguous; an opener whose mate differs ACROSS productions simply contributes
   several entries to the (set-valued) table, which is fine. *)
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
   EXACT pair (see [mates_of]): only a token in [closer]'s mate set counts as one of its
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

(* Would [token] plausibly open the construct [closer] terminates? Broader than
   the alias test in [find_matching_depth] on purpose: this is the lint's net for
   openers the alias table alone would miss. The alias-driven part is built in (a
   token whose alias begins with the opener character); the extra name-pattern
   nets come from the config file's [opener-nets] section, keyed by opener
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
