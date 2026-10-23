open Util
open Grammar
open Naming
open Delimiters
open Config
open Overrides

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
          (empty, or over the ≤5 cap) — what [stele fallbacks] shows an override
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
          emission or override. The [stele suggest-classes] clustering is over
          these raw sets. *)
  readable_len : int;
      (** The readable expected-list length with the *current* classes applied
          (List.length expected_symbols), for every entry — the
          [stele suggest-classes] impact simulation's baseline against the <=5
          cap. *)
  name_uses : name_use list;
      (** Every symbol this entry's *emitted* message actually rendered, with
          its rendered form, provenance, and position. Empty for an override
          (free prose) and for a generic fallback ("Syntax error", no symbol
          shown) — except that an over-cap fallback under a spurious reduction
          still shows its Assuming subject, which is recorded. The [names]
          review and the config-unused stat aggregate over these. *)
}

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
      StringMap.empty d.lr1_items
  in
  let vs_agg =
    symbols_of (fun _ -> true) |> StringMap.bindings |> List.map fst
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
        symbols_of grammar.is_generated |> StringMap.bindings |> List.map fst
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
             alias. When the closer has a UNIQUE mate, that mate is the opener,
             so print its alias verbatim (a compound '[|' reads "This '[|' …",
             underlined two characters). When the closer has SEVERAL mates (a
             ')' that closes '(', '(then', …), no single alias names them, so
             fall back to the shared opener character. *)
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
     reduction (the last in menhir's innermost→outermost list). The Expecting
     tokens are the FOLLOW of the outermost frame, so naming that frame keeps
     hedge and expectation coherent ("the instructions are complete, expecting
     'end'"), whereas the innermost would name the construct at the edit point
     but pair it with a FOLLOW token from a wider frame ("the parameters are
     complete, expecting 'end'"), and on deep cascades tends to surface
     low-level helper rules as the subject. *)
  let message_body, subject_marker =
    match List.rev d.spurious_reductions with
    | [] -> (base_message, None)
    | last :: _ ->
        let raw_name = fst (subject_name_src last.symbol) in
        (* The phrase loses its indefinite article ("a block" becomes "the
           block is"), and the verb agrees with it: singular after an article
           or for a quoted token, otherwise as the head noun reads, so an
           article-less [names] value such as "identifier" still gets "is". *)
        let name, verb =
          let stripped = strip_article raw_name in
          if stripped <> raw_name then (stripped, "is")
          else if String.length raw_name > 0 && raw_name.[0] = '\'' then
            (raw_name, "is")
          else (raw_name, if is_plural_phrase raw_name then "are" else "is")
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
  let header = header_of entry in
  let overridden, full_message =
    match StringMap.find_opt header overrides with
    | Some body ->
        validate_override_depths ~header body d.stack_suffix;
        (true, body)
    | None -> (false, generated_message)
  in

  Printf.bprintf buf "%s\n\n" full_message;

  (* Self-lints, reported by [stele stats]. An overridden entry is exempt:
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
        (if overridden then
           List.exists (fun (kind, _) -> kind = `Hint) (markers full_message)
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

(* Everything [generate_message] needs about one grammar, loaded once per
   [.cmly]: the token alias table, the grammar (with the config's [wrappers]
   folded in), the automaton the soundness oracle checks against, and the
   delimiter tables derived from the aliases. Shared by every review mode and by
   each [stele tune] trial. *)
type context = {
  cfg : config;
  terminals : (string, string) Hashtbl.t;
  grammar : gram;
  auto : automaton;
  closers : (string * char) list;
  mates : (string, StringSet.t) Hashtbl.t;
}

let load_context cfg cmly_file =
  let terminals, grammar0, auto = load_grammar cmly_file in
  let grammar = apply_wrapper_overrides cfg grammar0 in
  (* Closer terminals are derived from the token aliases, so a grammar that
     aliases its delimiters gets hints with no configuration. *)
  let closers = closers_of terminals in
  let mates = mates_of grammar terminals closers in
  { cfg; terminals; grammar; auto; closers; mates }

(* Generate the message of every entry, as (entry, (full text, message body,
   stat)). *)
let generate_all ctx ~comments ~overrides entries =
  List.map
    (fun entry ->
      ( entry,
        generate_message ctx.cfg ctx.closers ctx.mates ctx.grammar ctx.terminals
          ~comments ~overrides entry ))
    entries
