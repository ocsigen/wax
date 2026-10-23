open Util
open Grammar

(* --- Per-grammar configuration (the [--config] sidecar) --- *)

(* Everything grammar-specific that is not derivable from the [.cmly] lives in a
   hand-written config file, so the generator itself is grammar-agnostic. Three
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
          would keep them opaque. Rarely needed: the structural test recognises
          the standard library's wrappers and most hand-written ones. *)
}

let empty_config =
  {
    names = Hashtbl.create 1;
    classes = [];
    opener_nets = [];
    wrappers = StringSet.empty;
  }

(* Read the config file. Format (a hand-parsed line format, [#] comments,
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
  List.iteri
    (fun i raw ->
      let fail fmt =
        Printf.ksprintf
          (fun msg ->
            failwith (Printf.sprintf "config %s:%d: %s" file (i + 1) msg))
          fmt
      in
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
        else fail "unknown section header %S" line
      else
        match !section with
        | `None -> fail "line outside any section: %S" line
        | `Names -> (
            match String.index_opt line '=' with
            | None -> fail "[names]: no '=' in %S" line
            | Some i ->
                let key = String.trim (String.sub line 0 i) in
                let value =
                  String.trim
                    (String.sub line (i + 1) (String.length line - i - 1))
                in
                if Hashtbl.mem names key then
                  fail "[names]: duplicate entry for %S" key;
                if key = "" then fail "[names]: no name before '=' in %S" line;
                if value = "" then fail "[names]: empty value for %S" key;
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
                  | _ -> fail "[opener-nets]: unknown kind %S" kind
                in
                let c = ch.[0] in
                let existing = try Hashtbl.find nets c with Not_found -> [] in
                Hashtbl.replace nets c (existing @ [ net ])
            | _ -> fail "[opener-nets]: expected 'CHAR KIND ARG': %S" line))
    lines;
  {
    names;
    classes = List.rev_map (fun (l, m) -> (l, !m)) !classes;
    (* Sorted, so the order does not depend on the hash table's. *)
    opener_nets =
      Hashtbl.fold (fun c nets acc -> (c, nets) :: acc) nets []
      |> List.sort compare;
    wrappers = !wrappers;
  }

let net_matches token = function
  | Prefix p -> String.starts_with ~prefix:p token
  | Suffix s -> String.ends_with ~suffix:s token
  | Exact e -> token = e

(* The config sidecar's counterpart to [check_override_rot]: every entry must
   still name a symbol the grammar has, so a config left behind by a grammar
   change fails the build instead of firing on nothing. A [class] member must be
   a terminal; a [names] key a terminal or nonterminal; an [opener-nets] pattern
   must match at least one terminal (an unmatched net is a silently dead lint
   rule). Run when the config is loaded, so it needs the [.cmly] every config-consuming
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
  (* The base name of a parameterized rule ([function_type] for
     [function_type(in_type)]) is a valid [names] key: it names every
     instantiation. *)
  let is_parameterized_base head =
    StringSet.exists
      (fun n -> String.contains n '(' && base_symbol_name n = head)
      gram.all_nonterminals
  in
  (* Sorted, so the entry reported first does not depend on hashing. *)
  Hashtbl.fold (fun key _ acc -> key :: acc) cfg.names []
  |> List.sort compare
  |> List.iter (fun key ->
      if
        not
          (gram.is_terminal key || gram.is_nonterminal key
         || is_parameterized_base key)
      then stale "names" key);
  List.iter
    (fun (label, members) ->
      StringSet.iter
        (fun m ->
          if gram.is_nonterminal m then
            failwith
              (Printf.sprintf
                 "config %s [class %s]: %S is a rule, not a token (a class \
                  only groups tokens)"
                 file label m)
          else if not (gram.is_terminal m) then
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
   both are loaded; a no-op when [wrappers] is empty. *)
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
