open Util
open Grammar
open Config
open Overrides
open Generate
open Reports

(* ============================================================================
   The %on_error_reduce annotation tuner (`stele tune`)
   ============================================================================

   A read-only advisor: it RECOMMENDS single [%on_error_reduce] moves (adding or
   removing one annotation); it NEVER applies them, and it NEVER touches the
   source tree — every trial runs against a *copy* of the grammar in a
   throwaway scratch dir (removed on exit, even on failure or Ctrl-C).
   Single-move scores do not compose: two moves that each improve the messages
   can interact, so any set of moves applied together needs a fresh run.

   Menhir is a subprocess for this subcommand only: each trial re-runs
   [--list-errors] and [--cmly] on the mutated grammar copy. Everything else is
   in-process, through the same [Parse_messages.parse_file], [load_context],
   [generate_all] and [load_overrides] the other modes use, so the tuner scores
   exactly the messages and counters [stele stats] would show.

   EDITING THE GRAMMAR. The current annotations come from the [.cmly]
   ([Surface.on_error_reduce]); their place in the source comes from a light
   scan of the declarations ([tune_scan_annotations]), cross-checked against
   that list. A move edits the declarations in place, so every other
   annotation keeps its declaration and therefore its priority level.

   THE NO-OVERRIDES TRIAL CONSTRAINT (important — read before changing this).
   A trial that changes the annotation list can merge/renumber automaton states,
   which makes [menhir --list-errors] re-pick its representative sentence per
   state. The [.overrides] files are keyed by sentence, so a re-picked
   sentence can fail the generator's hard rot check ([check_override_rot]) and
   kill the trial. Therefore EVERY generation here runs WITHOUT overrides
   ([~overrides:StringMap.empty]), baseline and trials alike; the overridden
   states then sit uniformly on both sides of every comparison and the deltas
   stay meaningful. Consequence: the "over 5" fallback counter shows the raw
   pre-override figure — expected and correct for A/B deltas.

   THE PIPELINE PER TRIAL: [menhir COPY.mly --list-errors] and [menhir COPY.mly
   --cmly --no-code-generation --base X] into the scratch dir, then the in-process
   generator against those two artifacts and the grammar's config (the config
   carries the readable names/classes the goldens use, so a trial without it would
   diff spuriously). Candidate ADDITIONS are the nonterminals reduced somewhere in
   the automaton (see [tune_read_cmly]) minus the current list and the
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

(* The stats vector a trial is scored by. Each field is a plain count computed
   from the [message_stat] records and the soundness oracle, the same
   quantities [stele stats] prints. *)
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
  tv_nt_jargon : int;
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
  tt_jargon : StringSet.t;
      (** every name shown as jargon, token or rule, as "NAME (rendering)" *)
}

(* --- scratch + subprocess plumbing --- *)

let tune_read_file f = In_channel.with_open_bin f In_channel.input_all

let tune_write_file f s =
  Out_channel.with_open_bin f (fun oc -> Out_channel.output_string oc s)

let tune_rm_rf dir =
  if Sys.file_exists dir then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

(* A fresh uniquely-named scratch directory. [Filename.temp_dir] would do this
   but is OCaml 5.1+, and stele supports 4.14; so create a unique temp *file*
   (atomic), drop it, and mkdir in its place. The tiny race window is harmless
   for a build-time tool. *)
let tune_temp_dir () =
  let base = Filename.temp_file "stele-tune-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  base

(* Run [f] with a fresh scratch dir, guaranteed removed afterwards. [Fun.protect]
   covers a normal return or an exception (a bad grammar, a rot failure); the
   [at_exit] hook covers an uncaught exception that skips the [finally]; and the
   SIGINT handler turns Ctrl-C into a normal [exit], which runs [at_exit]. So the
   source tree is byte-identical after any run. *)
let tune_with_scratch f =
  let dir = tune_temp_dir () in
  at_exit (fun () -> tune_rm_rf dir);
  let prev = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> exit 130)) in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigint prev;
      tune_rm_rf dir)
    (fun () -> f dir)

(* Run the menhir command ([--menhir], split on blanks so that it can carry
   flags such as [--canonical]) with [args] appended, its stdout and stderr sent
   to the files [out] and [err] (which may be the same file), and return whether
   it succeeded. It is run directly rather than through [Sys.command], whose
   [system()] ignores SIGINT in stele while menhir runs: a Ctrl-C would kill only
   menhir, and the trial would read as a grammar menhir rejected. Here the
   SIGINT reaches stele as well (see [tune_with_scratch]), and a menhir killed
   by any signal stops the run. *)
let tune_run_menhir menhir args ~out ~err =
  match String.split_on_char ' ' menhir |> List.filter (fun s -> s <> "") with
  | [] -> failwith "--menhir: empty command"
  | prog :: flags -> (
      let open_out f =
        Unix.openfile f [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
      in
      let fd_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let fd_out = open_out out in
      let fd_err = if err = out then fd_out else open_out err in
      let pid =
        Fun.protect
          ~finally:(fun () ->
            Unix.close fd_in;
            Unix.close fd_out;
            if fd_err != fd_out then Unix.close fd_err)
          (fun () ->
            try
              Unix.create_process prog
                (Array.of_list ((prog :: flags) @ args))
                fd_in fd_out fd_err
            with Unix.Unix_error (e, _, _) ->
              failwith
                (Printf.sprintf "cannot run menhir command %S: %s" menhir
                   (Unix.error_message e)))
      in
      let rec wait () =
        try snd (Unix.waitpid [] pid)
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      in
      match wait () with
      | Unix.WEXITED 0 -> true
      | Unix.WEXITED _ -> false
      | Unix.WSIGNALED s | Unix.WSTOPPED s ->
          if s = Sys.sigint then exit 130
          else failwith (Printf.sprintf "menhir command %S was killed" menhir))

(* Verify the menhir command actually runs; a clear failure otherwise (caught at
   the top level and printed as a one-line [stele:] error). *)
let tune_check_menhir menhir =
  if
    not
      (tune_run_menhir menhir [ "--version" ] ~out:"/dev/null" ~err:"/dev/null")
  then
    failwith
      (Printf.sprintf
         "menhir command %S does not run (pass --menhir, or run under the opam \
          switch that provides menhir)"
         menhir)

(* What the tuner reads off a [.cmly]: the grammar's current [%on_error_reduce]
   annotations, in the order menhir lists them and without duplicates, and the
   nonterminals reduced somewhere in the automaton, other than the start
   symbols menhir adds, from which the candidate additions are drawn. *)
let tune_read_cmly cmly_file =
  let module G = MenhirSdk.Cmly_read.Read (struct
    let filename = cmly_file
  end) in
  let open G in
  let annots =
    List.fold_left
      (fun acc (name, _) -> if List.mem name acc then acc else name :: acc)
      [] Surface.on_error_reduce
    |> List.rev
  in
  (* A start symbol ([prog'], added by menhir) cannot be annotated. *)
  let s = ref StringSet.empty in
  let add p =
    let nt = Production.lhs p in
    if Nonterminal.kind nt = `REGULAR then
      s := StringSet.add (Nonterminal.name nt) !s
  in
  Lr1.iter (fun st ->
      (match Lr1.default_reduction st with Some p -> add p | None -> ());
      List.iter (fun (_, p) -> add p) (Lr1.get_reductions st));
  (annots, !s)

(* --- Locating and editing the %on_error_reduce declarations --- *)

(* One [%on_error_reduce] declaration of the grammar source: the offsets of its
   keyword and of the end of its last symbol, and each symbol it lists with its
   own [start, stop) span. A symbol's name has its blanks removed, so it
   compares equal to the [.cmly]'s spelling ([list( item )] is [list(item)]). *)
type oer_decl = {
  od_start : int;
  od_stop : int;
  od_symbols : (string * int * int) list;
}

(* Find the [%on_error_reduce] declarations in a grammar's declarations section
   (everything before the first [%%]), returning them in file order with the
   offset of that [%%]. A declaration may span several lines and hold comments;
   its symbols run until the next [%] keyword. This is a light lexer, not a
   parser: it skips comments ([/* */], nested [(* *)], [//]), the [%{ ... %}]
   header, string literals (token aliases) and [<...>] OCaml types, so that
   nothing inside them is mistaken for a declaration. The caller cross-checks the
   result against the annotations menhir itself reports. *)
let tune_scan_annotations src =
  let n = String.length src in
  let peek i = if i < n then src.[i] else '\000' in
  let starts_at i s =
    i + String.length s <= n && String.sub src i (String.length s) = s
  in
  let rec skip_past i stop =
    if i >= n then n
    else if starts_at i stop then i + String.length stop
    else skip_past (i + 1) stop
  in
  let rec skip_ocaml_comment i depth =
    if i >= n then n
    else if starts_at i "*)" then
      if depth = 1 then i + 2 else skip_ocaml_comment (i + 2) (depth - 1)
    else if starts_at i "(*" then skip_ocaml_comment (i + 2) (depth + 1)
    else skip_ocaml_comment (i + 1) depth
  in
  let rec skip_string i =
    if i >= n then n
    else
      match src.[i] with
      | '\\' -> skip_string (i + 2)
      | '"' -> i + 1
      | _ -> skip_string (i + 1)
  in
  (* As in menhir's lexer, a type ends at the first '>' that is not part of an
     arrow [->]; a '<' inside it opens nothing ([[< `A | `B ] -> unit]). *)
  let rec skip_type i =
    if i >= n then n
    else
      match src.[i] with
      | '>' when src.[i - 1] = '-' -> skip_type (i + 1)
      | '>' -> i + 1
      | _ -> skip_type (i + 1)
  in
  let is_blank c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let rec skip_trivia i =
    if i >= n then n
    else if is_blank src.[i] then skip_trivia (i + 1)
    else if starts_at i "/*" then skip_trivia (skip_past (i + 2) "*/")
    else if starts_at i "//" then skip_trivia (skip_past (i + 2) "\n")
    else if starts_at i "(*" then skip_trivia (skip_ocaml_comment (i + 2) 1)
    else i
  in
  let is_ident_start c =
    match c with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false
  in
  let is_ident_char c =
    is_ident_start c || match c with '0' .. '9' | '\'' -> true | _ -> false
  in
  let rec ident_end i =
    if i < n && is_ident_char src.[i] then ident_end (i + 1) else i
  in
  (* A symbol: an identifier, possibly applied to a parenthesised argument
     list ([list(item)], [separated_list(COMMA, item)]). *)
  let symbol_end i =
    let j = ident_end i in
    let k = skip_trivia j in
    if peek k = '(' then
      let rec close i depth =
        if i >= n then n
        else
          match src.[i] with
          | '(' -> close (i + 1) (depth + 1)
          | ')' -> if depth = 1 then i + 1 else close (i + 1) (depth - 1)
          | _ -> close (i + 1) depth
      in
      close k 0
    else j
  in
  let rec symbols i acc =
    let k = skip_trivia i in
    if k < n && is_ident_start src.[k] then
      let e = symbol_end k in
      let name =
        String.sub src k (e - k)
        |> String.to_seq
        |> Seq.filter (fun c -> not (is_blank c))
        |> String.of_seq
      in
      symbols e ((name, k, e) :: acc)
    else (i, List.rev acc)
  in
  let rec loop i decls =
    let i = skip_trivia i in
    if i >= n then failwith "grammar has no %% separator"
    else if starts_at i "%%" then (List.rev decls, i)
    else if starts_at i "%{" then loop (skip_past (i + 2) "%}") decls
    else
      match src.[i] with
      | '%' ->
          let j = ident_end (i + 1) in
          if String.sub src (i + 1) (j - i - 1) = "on_error_reduce" then
            let stop, syms = symbols j [] in
            loop stop
              ({ od_start = i; od_stop = stop; od_symbols = syms } :: decls)
          else loop j decls
      | '"' -> loop (skip_string (i + 1)) decls
      | '<' -> loop (skip_type (i + 1)) decls
      | _ -> loop (i + 1) decls
  in
  loop 0 []

(* The grammar source with one annotation move applied. [`Remove nt] deletes
   every listing of [nt], and drops a declaration it leaves empty (menhir
   rejects a bare [%on_error_reduce]); [`Add nt] appends [nt] to the last
   declaration, or adds a declaration just before [%%] when there is none. Every
   other annotation stays in its own declaration, so the priority levels menhir
   derives from declaration order are unchanged. *)
let tune_edit_annotations src (decls, sep) op =
  (* Apply sorted, non-overlapping (start, stop, replacement) edits. *)
  let splice edits =
    let b = Buffer.create (String.length src + 64) in
    let pos =
      List.fold_left
        (fun pos (a, z, r) ->
          Buffer.add_substring b src pos (a - pos);
          Buffer.add_string b r;
          z)
        0 edits
    in
    Buffer.add_substring b src pos (String.length src - pos);
    Buffer.contents b
  in
  match op with
  | `Remove nt ->
      List.concat_map
        (fun d ->
          if List.for_all (fun (s, _, _) -> s = nt) d.od_symbols then
            [ (d.od_start, d.od_stop, "") ]
          else
            List.filter_map
              (fun (s, a, z) -> if s = nt then Some (a, z, "") else None)
              d.od_symbols)
        decls
      |> splice
  | `Add nt -> (
      match List.rev decls with
      | d :: _ -> splice [ (d.od_stop, d.od_stop, " " ^ nt) ]
      | [] -> splice [ (sep, sep, "%on_error_reduce " ^ nt ^ "\n") ])

(* Run one grammar variant through menhir (subprocess) then the generator
   (in-process, override-free), returning its [tune_trial], or [None] when menhir
   rejected the mutated grammar (the caller skips the move); menhir's error
   output is left in [outprefix.err]. [mly] is the grammar file; [outprefix]
   names the scratch artifacts. *)
let tune_run_trial ~menhir ~cfg ~mly ~outprefix : tune_trial option =
  let messages = outprefix ^ ".messages"
  and cmly = outprefix ^ ".cmly"
  and err = outprefix ^ ".err" in
  (* Trials share their scratch prefix: clear the previous trial's artifacts so
     that a failed step can never pick up stale ones. *)
  List.iter (fun f -> if Sys.file_exists f then Sys.remove f) [ messages; cmly ];
  if
    not
      (tune_run_menhir menhir [ mly; "--list-errors" ] ~out:messages ~err
      && tune_run_menhir menhir
           [ mly; "--cmly"; "--no-code-generation"; "--base"; outprefix ]
           ~out:err ~err)
  then None
  else
    let entries = Parse_messages.parse_file messages in
    let ctx = load_context cfg cmly in
    let results =
      generate_all ctx ~comments:false ~overrides:StringMap.empty entries
    in
    let stats = List.map (fun (_, (_, _, s)) -> s) results in
    let count f = List.length (List.filter f stats) in
    let cascade =
      List.length
        (List.filter
           (fun (e, _) ->
             List.length e.Parse_messages.data.spurious_reductions >= 4)
           results)
    in
    let missed =
      List.fold_left (fun a s -> a + List.length s.missed_hints) 0 stats
    in
    let token_jargon =
      List.fold_left
        (fun a s -> StringSet.union a s.jargon)
        StringSet.empty stats
    in
    let jargon = StringSet.cardinal token_jargon in
    let nt_jargon = nonterminal_jargon stats in
    let oracle =
      List.map
        (fun (e, (_, _, s)) -> check_entry ctx.grammar ctx.auto (e, s))
        results
    in
    let unsound = List.fold_left (fun a (u, _) -> a + List.length u) 0 oracle in
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
        tv_nt_jargon = StringSet.cardinal nt_jargon;
        tv_unsound = unsound;
        tv_uncov_e = uncov_e;
        tv_uncov_t = uncov_t;
      }
    in
    Some
      {
        tt_vec = vec;
        tt_headers =
          List.fold_left
            (fun acc (e, _) -> StringSet.add (header_of e) acc)
            StringSet.empty results;
        tt_actual =
          List.map (fun (_, (text, _, _)) -> text) results
          |> List.sort String.compare;
        tt_census =
          census_counts (List.map (fun (_, (_, body, _)) -> body) results);
        tt_jargon =
          StringSet.fold
            (fun t acc ->
              StringSet.add
                (Printf.sprintf "%s ('%s')" t (String.lowercase_ascii t))
                acc)
            token_jargon nt_jargon;
      }

(* A move's verdict; the string is the short reason shown in the report. *)
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
  and d_nt_jargon = t.tv_nt_jargon - b.tv_nt_jargon
  and d_unsound = t.tv_unsound - b.tv_unsound
  and d_missed = t.tv_missed - b.tv_missed
  and d_uncov_e = t.tv_uncov_e - b.tv_uncov_e
  and d_uncov_t = t.tv_uncov_t - b.tv_uncov_t
  and d_template = t.tv_template - b.tv_template
  and d_cascade = t.tv_cascade - b.tv_cascade in
  (* Regression dominates: any single regressed counter classifies the move
     THarmful, tested before any improving signal, so a move that both regresses
     and improves is still reported HARMFUL. The exception is jargon: a name
     shown as jargon is fixed by a [names] entry, a token alias or a rule
     rename, without touching the annotations. So new jargon does not stop a
     move from being IMPROVING (the report lists the names as a caveat, see
     [tune_new_jargon]); it only makes HARMFUL a move with nothing to gain. *)
  if d_over5 > 0 then THarmful (Printf.sprintf "+%d over-5 fallback(s)" d_over5)
  else if d_empty > 0 then
    THarmful (Printf.sprintf "+%d empty-list fallback(s)" d_empty)
  else if d_hints < 0 then
    THarmful (Printf.sprintf "%d delimiter hint(s)" d_hints)
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
    else if d_jargon > 0 || d_nt_jargon > 0 then
      THarmful
        (Printf.sprintf "+%d jargon token(s), +%d jargon nonterminal(s)"
           d_jargon d_nt_jargon)
    else if
      base.tt_vec = trial.tt_vec
      && base.tt_actual = trial.tt_actual
      && base.tt_census = trial.tt_census
    then TDead
    else if (d_hints > 0 || d_cascade < 0) && d_template > 0 then
      let pointers n =
        if n = 1 then "1 message that points at the unclosed opener"
        else Printf.sprintf "%d messages that point at the unclosed opener" n
      in
      let gain =
        match (d_hints > 0, d_cascade < 0) with
        | true, true ->
            Printf.sprintf
              "gains %s and un-stacks %d deep \"Assuming ...\" message%s"
              (pointers d_hints) (-d_cascade)
              (if -d_cascade = 1 then "" else "s")
        | true, false -> Printf.sprintf "gains %s" (pointers d_hints)
        | false, _ ->
            Printf.sprintf "un-stacks %d deep \"Assuming ...\" message%s"
              (-d_cascade)
              (if -d_cascade = 1 then "" else "s")
      in
      let hedges =
        if d_template = 1 then "an \"Assuming ... is complete\" hedge"
        else "\"Assuming ... is complete\" hedges"
      in
      TMixed
        (Printf.sprintf "%s, but also turns %d message%s into %s" gain
           d_template
           (if d_template = 1 then "" else "s")
           hedges)
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
  counter (t.tv_over5 - b.tv_over5)
    "state that gives up with a bare \"Syntax error\" (too many options to \
     list)"
    "states that give up with a bare \"Syntax error\" (too many options to \
     list)";
  counter (t.tv_empty - b.tv_empty)
    "state that gives up with a bare \"Syntax error\" (nothing legal to list)"
    "states that give up with a bare \"Syntax error\" (nothing legal to list)";
  counter (t.tv_hints - b.tv_hints) "message that points at the unclosed opener"
    "messages that point at the unclosed opener";
  counter
    (t.tv_template - b.tv_template)
    "\"Assuming ... is complete\" message"
    "\"Assuming ... is complete\" messages";
  counter
    (t.tv_cascade - b.tv_cascade)
    "\"Assuming ...\" message stacked 4+ constructs deep"
    "\"Assuming ...\" messages stacked 4+ constructs deep";
  (let d_e = t.tv_uncov_e - b.tv_uncov_e
   and d_t = t.tv_uncov_t - b.tv_uncov_t in
   if d_e <> 0 then
     let head =
       tune_counter_clause d_e
         "state whose \"Expecting\" list omits a legal token"
         "states whose \"Expecting\" list omits a legal token"
     in
     if d_t <> 0 then
       add
         (Printf.sprintf "%s (%d %s omitted token%s in all)" head (abs d_t)
            (if d_t < 0 then "fewer" else "more")
            (if abs d_t = 1 then "" else "s"))
     else add head
   else if d_t <> 0 then
     add
       (Printf.sprintf "%d %s omitted legal token%s" (abs d_t)
          (if d_t < 0 then "fewer" else "more")
          (if abs d_t = 1 then "" else "s")));
  counter
    (t.tv_jargon - b.tv_jargon)
    "token shown as raw grammar jargon" "tokens shown as raw grammar jargon";
  counter
    (t.tv_nt_jargon - b.tv_nt_jargon)
    "rule name shown as code jargon" "rule names shown as code jargon";
  counter
    (t.tv_unsound - b.tv_unsound)
    "message listing a token the parser would refuse"
    "messages listing a token the parser would refuse";
  if t.tv_entries <> b.tv_entries then
    add
      (Printf.sprintf "distinct failure points: %d \xe2\x86\x92 %d" b.tv_entries
         t.tv_entries);
  if t.tv_withlist <> b.tv_withlist then
    add
      (Printf.sprintf
         "failure points that get an \"Expecting ...\" list: %d \xe2\x86\x92 %d"
         b.tv_withlist t.tv_withlist);
  match List.rev !clauses with
  | [] -> "    No counted change."
  | clauses -> "    " ^ tune_capitalize (String.concat "; " clauses) ^ "."

(* A census diff (baseline vs trial), keyed by normalized body: one [-]/[+] pair
   per body whose count changed, sorted by body: what the census golden's diff
   would show if the move were applied. *)
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

(* Everything the moves share: the grammar source and where its annotations
   sit, the scratch copy each trial rewrites, the loaded config, the
   override-free baseline, and the override keys used to price each move. *)
type tune_setup = {
  ts_src : string;
  ts_decls : oer_decl list * int;
      (** the source's [%on_error_reduce] declarations and its [%%] offset *)
  ts_annots : string list;  (** the current annotations *)
  ts_ignored : string list;
      (** annotations in the source that menhir ignores (on %inline symbols) *)
  ts_reducible : StringSet.t;  (** the nonterminals the baseline reduces *)
  ts_mly : string;  (** the scratch grammar copy, mutated per trial *)
  ts_cfg : config;
  ts_menhir : string;
  ts_base : tune_trial;
  ts_override_keys : string list;
}

(* Copy the grammar into scratch, compute the override-free baseline, and
   locate the annotations in the source. The config is loaded and checked for
   rot once, here, rather than in every trial. *)
let tune_setup ~menhir ~config_file ~overrides_file ~grammar_file ~scratch =
  let src = tune_read_file grammar_file in
  let decls = tune_scan_annotations src in
  (* Keep the file's name, so that menhir's error messages name it. *)
  let mly = Filename.concat scratch (Filename.basename grammar_file) in
  tune_write_file mly src;
  let cfg =
    if config_file = "" then empty_config else load_config config_file
  in
  let base_prefix = Filename.concat scratch "base" in
  let base =
    match tune_run_trial ~menhir ~cfg ~mly ~outprefix:base_prefix with
    | Some t -> t
    | None ->
        failwith
          (Printf.sprintf "menhir could not process %s:\n%s" grammar_file
             (String.trim (tune_read_file (base_prefix ^ ".err"))))
  in
  let base_cmly = base_prefix ^ ".cmly" in
  if config_file <> "" then begin
    let _, gram, _ = load_grammar base_cmly in
    check_config_rot ~file:config_file gram cfg
  end;
  let annots, reducible = tune_read_cmly base_cmly in
  (* The edits are only sound if the scan found every annotation menhir
     reports; anything else (a layout the scanner does not understand) is a
     clean error rather than a silently wrong trial. The scan may find more:
     menhir accepts, but ignores with a warning, an annotation on an %inline
     symbol, and leaves it out of its list. Those are reported as dead. *)
  let scanned =
    List.concat_map
      (fun d -> List.map (fun (s, _, _) -> s) d.od_symbols)
      (fst decls)
    |> List.sort_uniq compare
  in
  if not (List.for_all (fun a -> List.mem a scanned) annots) then
    failwith
      (Printf.sprintf
         "could not locate the %%on_error_reduce declarations of %s (menhir \
          reports [%s], the source scan found [%s])"
         grammar_file (String.concat " " annots)
         (String.concat " " scanned));
  let ignored = List.filter (fun s -> not (List.mem s annots)) scanned in
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
    ts_decls = decls;
    ts_annots = annots;
    ts_ignored = ignored;
    ts_reducible = reducible;
    ts_mly = mly;
    ts_cfg = cfg;
    ts_menhir = menhir;
    ts_base = base;
    ts_override_keys = override_keys;
  }

(* Build the trial grammar for a move and evaluate it. [op] is `Remove or `Add.
   Every trial reuses the single "trial" scratch prefix, overwriting the previous
   trial's artifacts — trials run sequentially, so this bounds scratch growth. *)
let tune_move ts op nt =
  let edit, expected =
    match op with
    | `Remove -> (`Remove nt, List.filter (fun a -> a <> nt) ts.ts_annots)
    | `Add -> (`Add nt, nt :: ts.ts_annots)
  in
  tune_write_file ts.ts_mly (tune_edit_annotations ts.ts_src ts.ts_decls edit);
  let outprefix = Filename.concat (Filename.dirname ts.ts_mly) "trial" in
  let trial =
    tune_run_trial ~menhir:ts.ts_menhir ~cfg:ts.ts_cfg ~mly:ts.ts_mly ~outprefix
  in
  (* Confirm the edit did what it meant to, as menhir sees it, so that a trial
     is never scored on the wrong grammar. An added annotation menhir ignores
     (on an %inline symbol) is a move menhir does not accept: no trial. *)
  match trial with
  | None -> None
  | Some _ ->
      let actual, _ = tune_read_cmly (outprefix ^ ".cmly") in
      let sorted l = List.sort compare l in
      if sorted actual = sorted expected then trial
      else if op = `Add && sorted actual = sorted ts.ts_annots then None
      else
        failwith
          (Printf.sprintf
             "internal error: editing the annotations for \"%s %s\" gave [%s] \
              instead of [%s]"
             (match op with `Remove -> "remove" | `Add -> "add")
             nt (String.concat " " actual)
             (String.concat " " expected))

(* --- the three report parts --- *)

(* The names a move would newly show as jargon, sorted. They are fixed in the
   config or the grammar's naming, not in the annotations, so the report lists
   them as a caveat on an improving move instead of rejecting it. *)
let tune_new_jargon ~base ~trial =
  StringSet.elements (StringSet.diff trial.tt_jargon base.tt_jargon)

let tune_print_jargon_caveat = function
  | [] -> ()
  | names ->
      Printf.printf
        "    Caveat: it would show these names as jargon. Give each a readable\n\
        \    name first (a [names] entry, a token alias, or a rule rename):\n";
      List.iter (fun n -> Printf.printf "      %s\n" n) names

(* Plain phrasing shared by the improving-collateral and relocates sections:
   the N hand-written messages (from the [.overrides] file) whose key sentences
   the trial's state merge/renumber changes. *)
let tune_rekey_phrase rc =
  if rc = 1 then "1 hand-written override"
  else Printf.sprintf "%d hand-written overrides" rc

let tune_dead_sweep ts =
  Printf.printf
    "### DEAD SWEEP: which constructs on the list are not doing anything?\n\
     Removing one that changes no message at all means it can be dropped.\n\n";
  List.iter
    (fun nt ->
      Printf.printf
        "  ---- remove %s\n\
        \    DEAD: menhir ignores it (an %%inline symbol is never reduced); \
         safe to delete\n"
        nt)
    ts.ts_ignored;
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
                \    DEAD: every generated message stays byte-identical; safe \
                 to delete\n"
                nt;
              n + 1
            end
            else n)
      (List.length ts.ts_ignored)
      ts.ts_annots
  in
  Printf.printf "  dead constructs found: %d\n\n" dead

(* Rank every single add/remove move, bucketing each into improving,
   relocates-overridden (see the [rc = gn] note below), or mixed, and tallying
   the harmful / neutral / dead / skipped rest. The subtlest step is the
   improving-vs-relocates split at the [tune_gain] match. *)
let tune_advisor ts candidates =
  Printf.printf
    "### ADVISOR: should any single construct join or leave the list?\n\
     Trying %d removal(s) and %d addition(s), one at a time. Each is scored only\n\
     by how it changes the generated messages; the scores do not add up, so\n\
     apply one, re-run, and see what opens up next.\n\n"
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
            let jn = tune_new_jargon ~base:ts.ts_base ~trial in
            (* Exact equality [rc = gn] means the whole measurable win lands on
               states the [.overrides] file already serves, so applying the move
               relocates hand-written work without net gain: RELOCATES-OVERRIDDEN.
               When the rot is smaller than the gain ([rc < gn]) the surplus falls
               on fresh states, so the move stays IMPROVING and is only
               rot-flagged (the [| _ ->] branch). *)
            match gain with
            | Some (gk, gn) when rc > 0 && gn > 0 && rc = gn ->
                relocates := (label, gk, rc, rot, vec, jn) :: !relocates
            | _ ->
                let cen = tune_census_diff ts.ts_base trial in
                improving :=
                  (label, reason, rc, rot, vec, cen, jn) :: !improving))
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
    "  what each group means, and what to do with it:\n\
    \    improving             some message gets better, none gets worse; \
     consider applying\n\
    \                          (after naming any jargon it lists)\n\
    \    relocates-overridden  its only gains are on states you already \
     hand-wrote\n\
    \                          a message for; usually skip (details below)\n\
    \    mixed                 helps one way and hurts another; read the wording\n\
    \                          changes and judge (details below)\n\
    \    harmful               some message gets worse; do not apply\n\
    \    dead/no-op            no message changes at all: an annotation on the \
     list\n\
    \                          can be dropped, one not on it is not worth adding\n\
    \    neutral               messages reshuffle with no net gain or loss; \
     usually skip\n\
    \    skipped               menhir rejected the grammar with this move; not \
     applicable\n\n";
  if improving = [] then
    Printf.printf
      "  No single move improves the messages outright (the usual result once\n\
      \  the list is already well-tuned).\n"
  else begin
    Printf.printf
      "  IMPROVING: each of these makes some message better and none worse,\n\
      \  apart from any names it lists as jargon. Review one at a time (the\n\
      \  scores do not add up):\n";
    List.iter
      (fun (label, _reason, rc, rot, vec, cen, jn) ->
        Printf.printf "  ---- %s\n%s\n" label vec;
        tune_print_jargon_caveat jn;
        if rc > 0 then begin
          Printf.printf
            "    It also shifts the sample input that keys %s, so that\n\
            \    hand-written message would need re-pointing; confirm the\n\
            \    generated message still beats each (keyed by these inputs):\n"
            (tune_rekey_phrase rc);
          List.iter (fun k -> Printf.printf "      %s\n" k) rot
        end;
        Printf.printf "    resulting wording changes:\n%s\n" cen)
      improving
  end;
  Printf.printf "\n";
  if relocates <> [] then begin
    Printf.printf
      "  RELOCATES-OVERRIDDEN: the improvement here lands entirely on states you\n\
      \  have already hand-written a message for, so applying it would only move\n\
      \  that hand-written work around, for no net gain. Apply only if the\n\
      \  generated message would actually read better than the hand-written one:\n";
    List.iter
      (fun (label, _gk, rc, rot, vec, jn) ->
        Printf.printf "  ---- %s\n%s\n" label vec;
        tune_print_jargon_caveat jn;
        Printf.printf
          "    Re-points %s (each keyed by the sample input that triggers it):\n"
          (tune_rekey_phrase rc);
        List.iter (fun k -> Printf.printf "      %s\n" k) rot)
      relocates;
    Printf.printf "\n"
  end;
  if mixed <> [] then begin
    Printf.printf
      "  MIXED: each of these helps one way and hurts another. It gains\n\
      \  messages that point at the unclosed opener, or un-stacks deep\n\
      \  \"Assuming ...\" messages, but also turns other messages into\n\
      \  \"Assuming ... is complete\" hedges. Judge case by case:\n";
    List.iter
      (fun (label, reason) -> Printf.printf "  ---- %s\n    %s\n" label reason)
      mixed;
    Printf.printf "\n"
  end

(* Parse a verdicts file: lines [keep NT] / [removed NT], [#] comments and blanks
   ignored. Returns (kept, removed). *)
let tune_parse_verdicts file =
  Parse_messages.read_lines file
  |> List.mapi (fun i line -> (i + 1, line))
  |> List.fold_left
       (fun (kept, removed) (lineno, line) ->
         let fail fmt =
           Printf.ksprintf
             (fun msg ->
               failwith (Printf.sprintf "verdicts %s:%d: %s" file lineno msg))
             fmt
         in
         let t = String.trim line in
         if t = "" || t.[0] = '#' then (kept, removed)
         else
           match String.index_opt t ' ' with
           | None -> fail "malformed line %S" line
           | Some i -> (
               let verb = String.sub t 0 i in
               (* Spelled as menhir does, without blanks: [list(item)]. *)
               let nt =
                 String.sub t i (String.length t - i)
                 |> String.to_seq
                 |> Seq.filter (fun c -> not (List.mem c [ ' '; '\t' ]))
                 |> String.of_seq
               in
               if nt = "" then fail "malformed line %S" line;
               match verb with
               | "keep" -> (nt :: kept, removed)
               | "removed" -> (kept, nt :: removed)
               | _ -> fail "unknown verb %S (expected 'keep' or 'removed')" verb
               ))
       ([], [])
  |> fun (kept, removed) -> (List.rev kept, List.rev removed)

(* Replay a recorded keep/remove log: removing a KEPT annotation and re-adding a
   REMOVED one should each be non-improving. Reports the agreement fraction and
   every disagreement — the deliverable of this part. *)
let tune_calibrate ts ~kept ~removed =
  Printf.printf
    "### CALIBRATION: replay the recorded keep/remove decisions\n\
    \  (removing a kept construct, or re-adding a removed one, must score \
     non-improving)\n";
  let agree = ref 0 and total = ref 0 and disagree = ref [] in
  let disagreement fmt =
    Printf.ksprintf
      (fun d ->
        incr total;
        disagree := d :: !disagree)
      fmt
  in
  let is_improving = function TImproving _ -> true | _ -> false in
  (* A verdict that no longer matches the list is a disagreement too: the log
     names a rule that was renamed, or an annotation that came back or went
     away since. Checked first, so a stale name never scores as a no-op. *)
  List.iter
    (fun nt ->
      if List.mem nt ts.ts_ignored then
        disagreement "kept %s, but menhir ignores it (an %%inline symbol)" nt
      else if not (List.mem nt ts.ts_annots) then
        disagreement "kept %s, but it is not on the list (stale name?)" nt
      else
        match tune_move ts `Remove nt with
        (* A kept annotation menhir won't let us remove is inert: skip it (not
           even counted in [total]). *)
        | None -> ()
        | Some trial ->
            if is_improving (tune_classify ~base:ts.ts_base ~trial) then
              disagreement
                "kept %s, but removing it now scores as an improvement" nt
            else (
              incr total;
              incr agree))
    kept;
  List.iter
    (fun nt ->
      if List.mem nt ts.ts_annots then
        disagreement "removed %s, but it is on the list" nt
      else
        match tune_move ts `Add nt with
        | None ->
            disagreement
              "removed %s, but menhir does not accept adding it back (stale \
               name, or an %%inline symbol?)"
              nt
        | Some trial ->
            if is_improving (tune_classify ~base:ts.ts_base ~trial) then
              disagreement
                "removed %s, but re-adding it now scores as an improvement" nt
            else (
              incr total;
              incr agree))
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
      Printf.printf "grammar: %s\n\n" grammar_file;
      Printf.printf
        "This tool tunes one thing: the grammar's %%on_error_reduce list. For\n\
         each construct on that list, when the parse fails just after the\n\
         construct is complete, its error message reads \"Assuming that the\n\
         <construct> is complete, expecting ...\" instead of listing everything\n\
         the construct itself could have continued with. Adding a construct to\n\
         the list trades a plain \"Expecting ...\" list for that \"Assuming \
         ...\"\n\
         phrasing; removing one does the reverse.\n\n";
      Printf.printf "on the list now (%d): %s\n\n" (List.length ts.ts_annots)
        (if ts.ts_annots = [] then "(none)" else String.concat " " ts.ts_annots);
      if ts.ts_ignored <> [] then
        Printf.printf
          "also annotated, but ignored by menhir (%%inline symbols, run `stele \
           tune dead`): %s\n\n"
          (String.concat " " ts.ts_ignored);
      (match mode with
      | Tune_dead -> tune_dead_sweep ts
      | Tune_advise ->
          let candidates =
            StringSet.elements ts.ts_reducible
            |> List.filter (fun nt ->
                (not (involves_anonymous nt)) && not (List.mem nt ts.ts_annots))
          in
          tune_advisor ts candidates
      | Tune_calibrate verdicts_file ->
          let kept, removed = tune_parse_verdicts verdicts_file in
          tune_calibrate ts ~kept ~removed);
      (* On stderr, so that stdout is a deterministic report. *)
      Printf.eprintf "finished in %.0fs\n" (Unix.gettimeofday () -. start))
