(* stele's generator: turns a Menhir grammar's [--list-errors] sentences and its
   [.cmly] into user-friendly syntax-error messages, and also drives the
   stats/census/names review modes and the [stele tune] annotation advisor. The
   generation heuristics, the sidecar file formats, and the review workflow are
   documented for users in stele's README and TUTORIAL.

   This file is the command line. The modules, in dependency order:
   - [Parse_messages]: the [menhir --list-errors] parser;
   - [Util]: string sets and maps, small helpers;
   - [Grammar]: the [.cmly] reader and the continuation (FIRST-set) walk;
   - [Config]: the [--config] sidecar and its rot check;
   - [Naming]: how a symbol is turned into words;
   - [Delimiters]: opener/closer pairing and the delimiter-hint depth;
   - [Overrides]: the [--overrides] sidecar and its checks;
   - [Generate]: [generate_message], the core per-state rendering;
   - [Reports]: the stats/census/names/fallbacks/suggest-classes/transitions
     outputs and the soundness oracle;
   - [Tune]: [stele tune]. *)

open Util
open Config
open Overrides
open Generate
open Reports
open Tune

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
  let cfg =
    if config_file = "" then empty_config else load_config config_file
  in
  let ctx = load_context cfg cmly_file in
  (* Rot protection: every config entry must still name a live grammar symbol,
     in every config-consuming mode. *)
  if config_file <> "" then check_config_rot ~file:config_file ctx.grammar cfg;
  match mode with
  | Transitions -> analyze_transitions ctx.closers ctx.mates ctx.grammar entries
  | Generate _ | Stats | Census | Names | Fallbacks | Suggest_classes -> (
      let comments = match mode with Generate nc -> not nc | _ -> true in
      (match mode with
      | Generate _ -> Printf.eprintf "Generating messages...\n"
      | _ -> ());
      let results = generate_all ctx ~comments ~overrides entries in
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
                  String.compare (header_of e1) (header_of e2))
                results
            else results
          in
          List.iter (fun (_, (text, _, _)) -> print_string text) to_print
      | Census ->
          output_census (List.map (fun (_, (_, body, _)) -> body) results)
      | Stats -> output_stats cfg ctx.grammar ctx.auto (stats_of ())
      | Names ->
          output_names ~overrides_active:(overrides_file <> "") cfg
            (stats_of ())
      | Fallbacks -> output_fallbacks (stats_of ())
      | Suggest_classes -> output_suggest_classes cfg (stats_of ())
      | Transitions -> assert false)

(* --- Command-line interface (cmdliner) --- *)

open Cmdliner
open Term.Syntax

(* The three shared grammar sidecars and the positional [.messages] file, common
   to every subcommand. *)
let cmly_arg =
  let doc =
    "Path to the grammar's $(b,.cmly) file, written by $(b,menhir --cmly): \
     stele reads the grammar's rules and token aliases from it. Required by \
     every command."
  in
  Arg.(required & opt (some string) None & info [ "cmly" ] ~docv:"FILE" ~doc)

let config_arg =
  let doc =
    "Path to the grammar's config file: readable names, token classes, and the \
     other per-grammar settings the README describes. Optional."
  in
  Arg.(value & opt string "" & info [ "config" ] ~docv:"FILE" ~doc)

let overrides_arg =
  let doc =
    "Path to the grammar's overrides file: hand-written messages that replace \
     the generated ones, each keyed by the sample input of an error state. An \
     override whose sample input matches no error state is an error. Optional."
  in
  Arg.(value & opt string "" & info [ "overrides" ] ~docv:"FILE" ~doc)

let messages_arg =
  let doc =
    "The output of $(b,menhir --list-errors): every error state, with a sample \
     input that reaches it."
  in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"MESSAGES" ~doc)

let no_comments_arg =
  let doc =
    "Leave out menhir's $(b,##) comments (state numbers and grammar items) and \
     sort the messages by sample input, so that the output stays the same when \
     states are renumbered. Use this for the golden file."
  in
  Arg.(value & flag & info [ "no-comments" ] ~doc)

let generate_cmd =
  let doc = "Write a message for every error state" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Write a syntax-error message for every error state in $(i,MESSAGES): \
         what could come next (\"Expecting ...\"), a hint pointing at the \
         opening delimiter the input is still inside, and, where the grammar \
         uses $(b,%on_error_reduce), the construct the parser assumed complete \
         (\"Assuming that ... is complete\"). Overrides replace the messages \
         they cover. $(b,menhir --compile-errors) turns the output into a \
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
  let doc = "Print counters that measure the messages' quality" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print how many error states get each kind of message (an Expecting \
         list, an \"Assuming\" hedge, a bare \"Syntax error\"), how many \
         delimiter hints there are and how many are missing, the names shown \
         as jargon, and the checks of the messages against the parser's \
         tables. A line per $(b,[class]) says how many states use it, and \
         unused $(b,[names]) entries are listed. Pin the output in a golden \
         file: a change that makes the messages worse then shows up as a diff.";
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
  let doc = "Print each distinct message once, with a count" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print each distinct message once, with the number of error states \
         that use it, sorted by message. Sample inputs do not appear, and \
         marker positions are written $(b,<_>), so a wording change is a \
         one-line diff, and a change of sample input at most changes a count.";
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
  let doc = "Show how each symbol is turned into words" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print a table of every grammar symbol a message shows: how it reads, \
         which naming rule produced it (token alias, $(b,[names]) entry, \
         element of a list or option, plural of that element, rule name, \
         $(b,[class]) label, or token name), and how often it appears in an \
         Expecting list and as the subject of an \"Assuming\" hedge. Then list \
         the $(b,[names]) entries that nothing uses. Use it to find names that \
         read badly, and config entries that can go.";
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
  let doc = "Print an override to fill in for each \"Syntax error\" state" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "For every state whose message is a bare \"Syntax error\" and that no \
         override covers, print a block to paste into the overrides file: \
         menhir's comments on the state, what could come next there, the \
         sample input that keys it, and a placeholder message. Empty output \
         means every such state is covered.";
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
  let doc = "Propose [class] entries for the config" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Propose $(b,[class]) blocks for the config file: groups of three or \
         more tokens, in no class yet, that are always accepted in the same \
         error states, so that one label can stand for them without hiding a \
         token. Groups are ranked by how many Expecting lists they would bring \
         under the five-item limit. Empty output means no group is worth a \
         class.";
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
  let doc = "List what could come next in each error state (debug)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "For every error state, list each symbol that could come next, marking \
         those that can only follow once the current construct is complete \
         ($(b,[lookahead])) and, for a closing token, where its opening \
         delimiter is. A view for debugging stele itself.";
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
    "Path to the grammar's $(b,.mly) file. Each trial edits a copy in a \
     temporary directory; your file is never changed."
  in
  Arg.(required & opt (some string) None & info [ "grammar" ] ~docv:"FILE" ~doc)

let menhir_arg =
  let doc =
    "The menhir command each trial runs. It may carry flags, separated by \
     spaces, such as $(b,\"menhir --canonical\") for a grammar built with \
     $(b,--canonical)."
  in
  Arg.(value & opt string "menhir" & info [ "menhir" ] ~docv:"CMD" ~doc)

let verdicts_arg =
  let doc =
    "Path to a log of past decisions: one $(b,keep RULE) or $(b,removed RULE) \
     per line; $(b,#) comments and blank lines are ignored."
  in
  Arg.(
    required & opt (some string) None & info [ "verdicts" ] ~docv:"FILE" ~doc)

let tune_dead_cmd =
  let doc = "Find %on_error_reduce annotations whose removal changes nothing" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Remove each $(b,%on_error_reduce) annotation in turn, and report \
         those whose removal changes no message at all: they can be deleted. \
         Annotations that menhir ignores (on $(b,%inline) symbols) are \
         reported too.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ menhir = menhir_arg in
    run_tune Tune_dead ~menhir ~config_file:config ~overrides_file:""
      ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "dead" ~doc ~man) term

let tune_advise_cmd =
  let doc = "Try adding or removing each annotation, and rate the result" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Try each single change: removing an annotation, or adding one for a \
         rule the parser reduces somewhere. Each change is rated by how the \
         messages change. It is $(b,harmful) if some state gets a bare \
         \"Syntax error\" or loses a delimiter hint, or if a message lists a \
         token the parser would reject or leaves out one it accepts. Otherwise \
         it is $(b,improving) if it removes a \"Syntax error\", a left-out \
         token or an \"Assuming\" hedge; names it would show as jargon are \
         then listed as a caveat, since a config entry fixes them, and only \
         make harmful a change that improves nothing. A change that adds \
         hedges but gains delimiter hints or shortens long chains of hedges is \
         $(b,mixed); one that changes no message is $(b,dead); anything else \
         is $(b,neutral). An improving change whose whole gain lands on states \
         you already wrote overrides for is listed apart, as \
         $(b,RELOCATES-OVERRIDDEN). The tuner only recommends: apply one \
         change and run it again, since the ratings of several changes do not \
         add up.";
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
  let doc = "Check the tuner against past decisions" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Replay a log of past decisions ($(b,--verdicts)): removing a \
         $(b,keep) annotation, or adding back a $(b,removed) one, should not \
         rate as improving. Report how often the tuner agrees, and each \
         disagreement, including verdicts that no longer match the grammar. \
         Use it to check that the ratings still match your judgement after the \
         grammar or stele has changed.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ menhir = menhir_arg
    and+ verdicts = verdicts_arg in
    run_tune (Tune_calibrate verdicts) ~menhir ~config_file:config
      ~overrides_file:"" ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "calibrate" ~doc ~man) term

let tune_cmd =
  let doc = "Suggest changes to the %on_error_reduce annotations" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Suggest changes to the grammar's $(b,%on_error_reduce) annotations, \
         which decide where a message says \"Assuming that ... is complete\". \
         Each trial adds or removes one annotation in a temporary copy of the \
         grammar, runs menhir on it, regenerates the messages, and compares \
         them with the current ones. The tuner only recommends; it never \
         changes your files.";
      `P
        "Trials leave out the overrides file, because a changed annotation can \
         change the sample inputs that key the overrides. $(b,tune advise) \
         still reads it, to tell you which overrides a change would make you \
         re-key.";
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
        "stele writes the syntax-error messages of a Menhir grammar, one per \
         error state, saying what could come next. Pin them in golden files, \
         and a grammar change shows up as a diff of the messages to review.";
      `P
        "Every command except $(b,tune) reads the same inputs: the grammar's \
         $(b,.cmly) file ($(b,--cmly), required), an optional config file \
         ($(b,--config)), an optional overrides file ($(b,--overrides)), and \
         the output of $(b,menhir --list-errors) ($(i,MESSAGES)).";
      `S Manpage.s_commands;
      `S Manpage.s_examples;
      `P "Generate the messages for $(b,menhir --compile-errors):";
      `Pre
        "  $(mname) generate --cmly g.cmly --config g.config --overrides \
         g.overrides g.messages";
      `P "Print the quality counters:";
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

(* A user error (a stale sidecar entry, a malformed input, a missing file)
   raises [Failure] or [Sys_error]; render it as a clean one-line error and exit
   non-zero, rather than letting it escape as an uncaught-exception backtrace.
   [~catch:false] keeps cmdliner from turning it into a generic internal
   error. *)
let () =
  let code =
    try Cmd.eval ~catch:false main_cmd
    with Failure msg | Sys_error msg ->
      Printf.eprintf "stele: %s\n" msg;
      1
  in
  exit code
