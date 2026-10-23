open Util
open Grammar
open Config
open Naming
open Delimiters
open Generate

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
          StringMap.empty d.lr1_items
      in

      let symbols = StringMap.bindings all_next in
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

(* --- Soundness oracle --- *)

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
  (* The entry that named [sym]: its own, else its base name's (see
     [Naming.names_entry]). *)
  let key sym =
    if Hashtbl.mem cfg.names sym then sym else base_symbol_name sym
  in
  let counts =
    List.fold_left
      (fun m u ->
        (* A [names] entry fires either as the winning source directly, or as
           the element a chase resolved to (credited so [local_decl] under the
           [locals] chase is not mis-flagged as unused). *)
        let m =
          if u.nu_source = Names_entry then
            bump (key u.nu_symbol) u.nu_position m
          else m
        in
        match u.nu_credit with
        | Some (elem, Names_entry) -> bump (key elem) u.nu_position m
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

(* The auto-derived nonterminal names that read as code jargon, as
   "symbol (rendering)", over every name a shown message uses. Keyed on the
   *rendered* text, so it fires wherever the leak actually surfaces — including
   through a list named by its element ([stmts] shown as "a stmt"), where the
   name that leaks is the element's. *)
let nonterminal_jargon stats =
  List.fold_left
    (fun acc s ->
      List.fold_left
        (fun acc u ->
          let symbol =
            match (u.nu_source, u.nu_credit) with
            | Auto, _ -> Some u.nu_symbol
            | Chase, Some (elem, Auto) -> Some elem
            | _ -> None
          in
          match symbol with
          | Some sym when rendering_has_jargon_word u.nu_rendered ->
              StringSet.add (Printf.sprintf "%s (%s)" sym u.nu_rendered) acc
          | _ -> acc)
        acc s.name_uses)
    StringSet.empty stats

(* Aggregate the per-entry self-lints into the quality summary pinned by the
   promoted [parser_messages.stats.expected] goldens: regressions (a new
   fallback state, a lost hint, a jargon token) fail `dune runtest`;
   improvements are accepted with `dune promote`. *)
let output_stats cfg gram auto results =
  let count f = List.length (List.filter (fun (_, s) -> f s) results) in
  Printf.printf "error states: %d\n" (List.length results);
  Printf.printf "with an \"Expecting\" list: %d\n"
    (count (fun s -> s.expecting));
  Printf.printf "with an \"Assuming\" hedge: %d\n" (count (fun s -> s.assuming));
  (* Cascade depth = the number of spurious reductions folded before the error
     is reported (the length of the "Assuming …" chain). A deep cascade means
     the hedge names a construct far from where the user was editing, so these
     are counted to make over-annotation measurable. *)
  let cascade_depths =
    List.map
      (fun (entry, _) ->
        List.length entry.Parse_messages.data.spurious_reductions)
      results
  in
  Printf.printf "hedges assuming 4 or more constructs: %d\n"
    (List.length (List.filter (fun d -> d >= 4) cascade_depths));
  Printf.printf "most constructs assumed by one hedge: %d\n"
    (List.fold_left max 0 cascade_depths);
  (* Hand-written overrides. The fallback counters below exclude these
     (their [overflow_expected]/[empty_expected] are forced false), so
     "not overridden" is the new ratchet target: a genuinely un-overridable
     enumeration state that still degrades to "Syntax error". *)
  Printf.printf "overridden: %d\n" (count (fun s -> s.overridden));
  Printf.printf "\"Syntax error\", nothing to list (not overridden): %d\n"
    (count (fun s -> s.empty_expected));
  Printf.printf "\"Syntax error\", over 5 to list (not overridden): %d\n"
    (count (fun s -> s.overflow_expected));
  Printf.printf "delimiter hints: %d\n" (count (fun s -> s.hinted));
  let missed =
    List.concat_map
      (fun (entry, s) ->
        List.map (fun closer -> (closer, entry)) s.missed_hints)
      results
  in
  Printf.printf "missed delimiter hints (an opener is open, but no hint): %d\n"
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
  Printf.printf "tokens shown as jargon: %d\n" (StringSet.cardinal jargon);
  StringSet.iter (fun s -> Printf.printf "  %s\n" s) jargon;
  (* The nonterminal counterpart. The token lint above cannot see these: it opens
     with [String.uppercase_ascii s = s], true only of a terminal, so a nonterminal
     never reaches it. That blind spot shipped "a hinted unfolded" and "a
     compilation priority opt" while the token count still read 0; both were caught
     only by someone reading the message diff. Keyed on the *rendered* text of every
     auto-derived name a shown message uses, so it fires wherever the leak actually
     surfaces. *)
  let nt_jargon = nonterminal_jargon (List.map snd results) in
  Printf.printf "rule names shown as jargon: %d\n"
    (StringSet.cardinal nt_jargon);
  StringSet.iter (fun s -> Printf.printf "  %s\n" s) nt_jargon;

  (* Soundness oracle: claims-vs-automaton. *)
  let matched, total = check_correspondence auto (List.map fst results) in
  Printf.printf "states numbered as in the .cmly: %d/%d\n" matched total;
  let oracle = List.map (fun r -> (r, check_entry gram auto r)) results in
  let unsound_claims =
    List.concat_map
      (fun ((entry, _), (unsound, _)) ->
        List.map (fun sym -> (sym, entry)) unsound)
      oracle
  in
  Printf.printf "listed tokens the parser rejects: %d\n"
    (List.length unsound_claims);
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
  Printf.printf "lists missing an accepted token: %d\n"
    (List.length with_uncovered);
  Printf.printf "accepted tokens missing (total): %d\n" total_uncovered;
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
     supersede the phrase (as an operator state can), yet the
     class is live while its members still co-occur. N=0 is legitimate (a class
     waiting for a qualifying state) but now visible, so a class that goes quiet
     after a grammar change shows up as a golden diff. A grammar with no classes
     prints nothing. *)
  List.iter
    (fun (label, _) ->
      Printf.printf "class %S: applies in %d states\n" label
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
  (* Only at the start of a line, where the runtime reads markers (see
     [Overrides.markers]); a '<3>' elsewhere is prose. *)
  Str.global_replace (Str.regexp "^<\\(\\^?\\)[0-9]+>") "<\\1_>" body

(* Each distinct (depth-normalized) message body with its occurrence count,
   sorted by the message text. *)
let census_counts bodies =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun body ->
      let key = census_normalize body in
      let n = try Hashtbl.find tbl key with Not_found -> 0 in
      Hashtbl.replace tbl key (n + 1))
    bodies;
  Hashtbl.fold (fun msg count acc -> (msg, count) :: acc) tbl []
  |> List.sort (fun (m1, _) (m2, _) -> String.compare m1 m2)

(* Emit the message census: each distinct message body once, prefixed by its
   occurrence count. Entry sentences never appear, so sentence re-picking at
   most bumps a count and a wording change is a one-line diff. A multi-line body
   (hedge + delimiter hint) is one census item; its continuation lines are
   indented to the message column. *)
let output_census bodies =
  census_counts bodies
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
  let fallbacks =
    results
    |> List.filter (fun (_, stat) ->
        stat.empty_expected || stat.overflow_expected)
    |> List.sort (fun (e1, _) (e2, _) ->
        String.compare (header_of e1) (header_of e2))
  in
  Printf.eprintf "%d \"Syntax error\" state(s) without an override\n"
    (List.length fallbacks);
  List.iter
    (fun (entry, stat) ->
      List.iter print_endline entry.Parse_messages.original_comments;
      Printf.printf "# Could come next (%d): %s\n"
        (List.length stat.fallback_symbols)
        (String.concat ", " stat.fallback_symbols);
      Printf.printf "%s\n<YOUR SYNTAX ERROR MESSAGE HERE>\n\n" (header_of entry))
    fallbacks

(* Discovery aid: propose new [class] blocks for the config file by
   signature-clustering the raw expected sets. A terminal's *signature* is the
   set of entries whose raw expected list mentions it; terminals with the
   *identical* signature always co-occur, so collapsing them to one label never
   drops a token a single state needed. Terminals already in a configured class
   are excluded (they are handled); nothing else is filtered (see
   [is_candidate] below for why short punctuation is not). A
   cluster is kept only at >=3 members; ranked by impact — how
   many entries the collapse newly fits under the <=5 readable cap, then the
   total list-item reduction. Output is a paste-ready [class <LABEL>] block per
   cluster (label is a human decision, left as a placeholder), impact as [#]
   comments, in the [stele fallbacks] authoring-template style. Empty output
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
  Printf.eprintf "%d %s worth a [class] (3 or more always accepted together)\n"
    (List.length ranked)
    (if List.length ranked = 1 then "group of tokens" else "groups of tokens");
  List.iter
    (fun (members, k, states, newly_fits, reduction) ->
      let plural n word words = if n = 1 then word else words in
      Printf.printf
        "# %d tokens always accepted together, in %d %s. One label for them\n" k
        states
        (plural states "state" "states");
      Printf.printf
        "# brings %d Expecting %s under the five-item limit and removes %d %s.\n"
        newly_fits
        (plural newly_fits "list" "lists")
        reduction
        (plural reduction "item" "items");
      Printf.printf "[class <LABEL>]\n";
      List.iter print_endline members;
      print_newline ())
    ranked
