type syntax_error = {
  location : Wax_utils.Ast.location;
  message : Wax_utils.Message.t;
  related : Wax_utils.Diagnostic.label list;
  hint : Wax_utils.Message.t option;
  fix : Wax_utils.Diagnostic.edit option;
}

exception Syntax_error of syntax_error

(* Smart constructor: build the structured payload and raise. Every raise site
   (the two lexers and both grammars' semantic actions) funnels through this —
   directly or via a per-file thin wrapper that turns a position pair into the
   [Ast.location] — so the payload shape is spelled once here. [related]/[hint]
   enrich the diagnostic exactly as {!Wax_utils.Diagnostic} does; [fix] carries a
   machine-applicable quick fix (a text edit), reusing {!Wax_utils.Diagnostic.edit}
   so the editor/LSP code-action path is shared with the typer's suggestions. *)
let syntax_error ~location ?(related = []) ?hint ?fix message =
  raise (Syntax_error { location; message; related; hint; fix })

(* Build (without raising) the {!Syntax_error} value from the legacy
   position-pair payload [((loc_start, loc_end), message)]. The many raise sites
   in the two lexers and both grammars predate the structured record and read
   [raise (Syntax_error (pair, msg))]; routing them through this keeps each a
   one-token change ([Syntax_error] -> [syntax_error_pair]) while the record
   shape stays spelled once. New or enriched sites (attaching [related]/[hint]/
   [fix]) should use the raising {!syntax_error} instead. *)
let syntax_error_pair ((loc_start, loc_end), message) =
  Syntax_error
    {
      location = { Wax_utils.Ast.loc_start; loc_end };
      message;
      related = [];
      hint = None;
      fix = None;
    }

type sync_class = Open | Close | Boundary | Leader | Terminal | Skip

(* Internal marker raised by [fail_detailed] to carry a structured error out of
   [loop_handle] to [parse_diagnostics]; never escapes this module. *)
exception Detailed_error of syntax_error

(* Helpers independent of the functor parameters, shared by both {!Make} and
   {!Make_parser}. *)
module E = MenhirLib.ErrorReports
module Lu = MenhirLib.LexerUtil

let succeed v = v

let show text positions =
  E.extract text positions |> E.sanitize |> E.compress
  |> E.shorten 20 (* max width 43 *)

let report_syntax_error ~color source (e : syntax_error) =
  let theme = Wax_utils.Diagnostic.get_theme ?color () in
  Wax_utils.Diagnostic.output_error_with_source ~theme ~source ~severity:Error
    ~location:e.location ~related:e.related ?hint:e.hint ?edit:e.fix e.message;
  (* The diagnostic has been printed; re-raise so the caller decides how to
     terminate rather than exiting the process here. The CLI maps this to exit
     code 128 (rejected input, like a validation or type error, not the
     usage-error code; see the exit-code contract in bin/main.ml), while an
     in-process embedder can catch it instead of having the whole process die. *)
  raise (Syntax_error e)

let read filename = In_channel.with_open_bin filename In_channel.input_all

let initialize_lexing filename text =
  let lexbuf = Sedlexing.Utf8.from_string text in
  Sedlexing.set_filename lexbuf filename;
  lexbuf

(* [Lexer.token] returns the tokenizer and a [start_override] ref: for a
   compound opener ([(param], [(then], …) the lexer reads the [(] and its
   keyword as two lexemes, so the lexbuf's reported start is the keyword's; the
   ref carries the [(]'s position instead, so the token's span really begins at
   its opening parenthesis. *)
let lexer_lexbuf_to_supplier (lexer, start_override) (lexbuf : Sedlexing.lexbuf)
    () =
  let token = lexer lexbuf in
  let startp, endp = Sedlexing.lexing_bytes_positions lexbuf in
  let startp = match !start_override with Some p -> p | None -> startp in
  (token, startp, endp)

(* Core parser over a Menhir incremental API, without the fast parser: the
   incremental parser produces both the AST (happy path) and the error (with
   [Parser_messages]) in a single pass. Provides [parse_diagnostics] (structured
   error, no printing) and [parse_from_string] (prints and re-raises). *)
module Make (Output : sig
  type t
end) (Tokens : sig
  type token
end) (Parser : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (Parser_messages : sig
  val message : int -> string
end) (Lexer : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) =
struct
  module Inner (Context : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    module P = Parser.Make (Context)

    let state checkpoint : int =
      match checkpoint with
      | P.MenhirInterpreter.HandlingError env -> (
          match P.MenhirInterpreter.top env with
          | Some (Element (s, _, _, _)) -> P.MenhirInterpreter.number s
          | None -> 0)
      | _ -> assert false

    let rec positions_in_stack env i =
      match P.MenhirInterpreter.get i env with
      | Some (Element (_, _, pos1, pos2)) ->
          if false then Format.eprintf "%d--%d@." pos1.pos_cnum pos2.pos_cnum;
          positions_in_stack env (i + 1)
      | None -> ()

    let get text checkpoint i =
      match checkpoint with
      | P.MenhirInterpreter.HandlingError env -> (
          match P.MenhirInterpreter.get i env with
          | Some (Element (_, _, pos1, pos2)) -> show text (pos1, pos2)
          | None -> "???")
      | _ -> assert false

    (* Compute the structured diagnostic (location, message, related labels) for
       a menhir syntax error, without printing anything. Both the printing
       handler [fail] (for the CLI) and the non-printing [fail_detailed] (for
       in-process/editor use via [parse_diagnostics]) build on this. *)
    let build_syntax_error text buffer checkpoint =
      let env =
        match checkpoint with
        | P.MenhirInterpreter.HandlingError env -> env
        | _ -> assert false
      in
      positions_in_stack env 0;

      let location = E.last buffer in
      let s = state checkpoint in
      let message =
        try Parser_messages.message s
        with Not_found -> Printf.sprintf "Syntax error (%d)\n" s
      in
      let message =
        if message = "<YOUR SYNTAX ERROR MESSAGE HERE>\n" then
          Printf.sprintf "Syntax error (%d)\n" s
        else message
      in
      let message = E.expand (get text checkpoint) message in
      let lines = String.split_on_char '\n' message in
      let related = ref [] in
      let main_message = ref [] in
      List.iter
        (fun line ->
          let len = String.length line in
          if len > 2 && line.[0] = '<' then
            try
              let i = String.index line '>' in
              let depth = int_of_string (String.sub line 1 (i - 1)) in
              let msg = String.trim (String.sub line (i + 1) (len - i - 1)) in
              match P.MenhirInterpreter.get (depth - 1) env with
              | Some (Element (_, _, pos1, _pos2)) ->
                  (* This hint points at a single opening delimiter, so underline
                     one character. The delimiter is normally the token's start —
                     the lexer gives a compound opener ([(then]/[(param]/…) the
                     '(' as its start — but a spurious reduction can surface a
                     plain token (e.g. ELEM) sitting just past the '('; in that
                     case walk the source back over blanks to the delimiter. *)
                  let cnum = pos1.Lexing.pos_cnum in
                  let is_delim c = c = '(' || c = '[' || c = '{' in
                  let blank c = c = ' ' || c = '\t' in
                  let dcnum =
                    if cnum < String.length text && is_delim text.[cnum] then
                      cnum
                    else
                      let rec back i =
                        if i < 0 || not (blank text.[i]) then
                          if i >= 0 && is_delim text.[i] then i else cnum
                        else back (i - 1)
                      in
                      back (cnum - 1)
                  in
                  let start = { pos1 with Lexing.pos_cnum = dcnum } in
                  let loc =
                    {
                      Wax_utils.Ast.loc_start = start;
                      loc_end = { start with Lexing.pos_cnum = dcnum + 1 };
                    }
                  in
                  related :=
                    {
                      Wax_utils.Diagnostic.location = loc;
                      message = Wax_utils.Message.text msg;
                    }
                    :: !related
              | None -> main_message := line :: !main_message
            with _ -> main_message := line :: !main_message
          else main_message := line :: !main_message)
        lines;
      let main_message = List.rev !main_message in
      let related_labels = List.rev !related in
      (* Remove trailing empty line if it was caused by a trailing newline and we have related labels *)
      let main_message =
        match List.rev main_message with
        | "" :: rest when related_labels <> [] -> List.rev rest
        | _ -> main_message
      in
      let message = String.concat "\n" main_message in
      (location, message, related_labels)

    let fail_detailed text buffer checkpoint =
      let (loc_start, loc_end), message, related =
        build_syntax_error text buffer checkpoint
      in
      raise
        (Detailed_error
           {
             location = { Wax_utils.Ast.loc_start; loc_end };
             message = Wax_utils.Message.text message;
             related;
             hint = None;
             fix = None;
           })

    (* Parse, returning the AST or a structured syntax error, without printing:
       the incremental parser produces both, in a single pass. *)
    let parse_diagnostics ~filename text =
      let lexbuf = initialize_lexing filename text in
      let supplier =
        lexer_lexbuf_to_supplier (Lexer.token Context.context) lexbuf
      in
      let buffer, supplier = E.wrap_supplier supplier in
      let checkpoint =
        P.Incremental.parse (snd (Sedlexing.lexing_bytes_positions lexbuf))
      in
      try
        Ok
          (P.MenhirInterpreter.loop_handle succeed
             (fail_detailed text buffer)
             supplier checkpoint)
      with
      | Detailed_error e | Syntax_error e -> Error e
      | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
          let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
          Error
            {
              location = { Wax_utils.Ast.loc_start; loc_end };
              message =
                Wax_utils.Message.text
                  "Input file contains malformed UTF-8 byte sequences";
              related = [];
              hint = None;
              fix = None;
            }

    (* Panic-mode error recovery, sync-token variant. This uses only the
       vanilla [INCREMENTAL_ENGINE] API — no [error] productions in the grammar
       and no inspection-API [feed] — so it needs neither a grammar change nor
       [--inspection] on the generated parser. We drive [offer]/[resume] by hand
       (rather than [loop_handle], which stops at the first error) so that at a
       [HandlingError] checkpoint we still hold the offending token: to recover
       we skip forward to the next boundary token, unwind the stack with [pop]
       to a state that [acceptable] confirms can shift it, [offer] it, and carry
       on. Every error is collected; the returned AST is whatever the parser
       reduces to, with holes where erroneous spans were skipped. *)
    let parse_recover ~filename ~sync ?(insert = []) ?(closers = []) ?barrier
        text =
      let module MI = P.MenhirInterpreter in
      let lexbuf = initialize_lexing filename text in
      let errors = ref [] in
      (* Byte offset of the last position at which a token was inserted (see
         [try_insert]); guards against inserting twice at the same spot, which
         would otherwise loop when the insertion does not actually unblock the
         parse. *)
      let last_insert = ref (-1) in
      (* Raised when the lexer cannot make progress past a malformed byte; the
         error is already recorded, so the top-level handler just stops. *)
      let exception Lexing_gave_up in
      let record_error location message =
        errors :=
          { location; message; related = []; hint = None; fix = None }
          :: !errors
      in
      (* Lexer-level recovery. A bad character or malformed byte makes
         [Lexer.token] raise rather than surface as a parser [HandlingError];
         the lexer has already consumed the offending lexeme (e.g. the [Compl]
         catch-all matches one code point, then raises), so we record the error
         and retry, resuming past it — a stray character no longer truncates the
         whole parse. The position guard keeps the [parse_recover] termination
         invariant: if a raise made no progress (a byte the decoder cannot even
         skip), we give up lexing rather than spin. *)
      let base_supplier =
        lexer_lexbuf_to_supplier (Lexer.token Context.context) lexbuf
      in
      let cnum () =
        (Sedlexing.lexing_bytes_position_curr lexbuf).Lexing.pos_cnum
      in
      let rec recovering_supplier () =
        let before = cnum () in
        (* Error just recorded; retry past the offending lexeme, or give up if
           the raise made no progress. *)
        let resume () =
          if cnum () > before then recovering_supplier ()
          else raise Lexing_gave_up
        in
        try base_supplier () with
        | Syntax_error e ->
            record_error e.location e.message;
            resume ()
        | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
            let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
            record_error
              { Wax_utils.Ast.loc_start; loc_end }
              (Wax_utils.Message.text
                 "Input file contains malformed UTF-8 byte sequences");
            resume ()
      in
      let buffer, supplier = E.wrap_supplier recovering_supplier in
      (* Net open-parenthesis depth of the input consumed so far. Every token is
         pulled from [supplier] exactly once — by [run] on the happy path, by
         [find_sync] while skipping — so counting openers/closers here tracks the
         {e source} nesting at the current read position: how many openers
         enclose it, independent of parser state. Group-drop consults it to tell a
         genuinely-open inner group from a stray closer that follows an
         already-complete construct (where nothing is open). *)
      let paren_depth = ref 0 in
      let supplier () =
        let ((t, _, _) as tok) = supplier () in
        (match sync t with
        | Open -> incr paren_depth
        | Close -> decr paren_depth
        | Boundary | Leader | Terminal | Skip -> ());
        tok
      in
      let record checkpoint =
        let (loc_start, loc_end), message, related =
          build_syntax_error text buffer checkpoint
        in
        errors :=
          {
            location = { Wax_utils.Ast.loc_start; loc_end };
            message = Wax_utils.Message.text message;
            related;
            hint = None;
            fix = None;
          }
          :: !errors
      in
      (* A missing token, reported as a zero-width caret just before the
         offending token (where the inserted token belongs) — unless an error was
         already flagged ending at that very spot (only whitespace between). That
         happens when the lexer skipped a bad token there (a bare ["$"] the user
         is still turning into an identifier, say): its error already reports the
         gap, and the placeholder is inserted only to keep the tree well-formed,
         so a second "Missing …" caret on top would be redundant. *)
      let only_blank_between lo hi =
        let ok = ref (lo <= hi) in
        for i = lo to hi - 1 do
          match text.[i] with
          | ' ' | '\t' | '\n' | '\r' -> ()
          | _ -> ok := false
        done;
        !ok
      in
      let record_missing ?fix message (pos : Lexing.position)
          (end_pos : Lexing.position) =
        let already_flagged =
          match !errors with
          | { location; _ } :: _ ->
              let err_start =
                location.Wax_utils.Ast.loc_start.Lexing.pos_cnum
              in
              let err_end = location.Wax_utils.Ast.loc_end.Lexing.pos_cnum in
              if
                pos.Lexing.pos_cnum <= err_start
                && err_end <= end_pos.Lexing.pos_cnum
              then true
              else only_blank_between err_end pos.Lexing.pos_cnum
          | [] -> false
        in
        if not already_flagged then
          errors :=
            {
              location = { Wax_utils.Ast.loc_start = pos; loc_end = pos };
              message;
              related = [];
              hint = None;
              fix;
            }
            :: !errors
      in
      (* Return the token to resynchronize on: the next boundary (or terminal)
         reached by discarding tokens from the supplier. [tok0] is the token
         already in hand (the one that triggered the error, if any); if it is
         itself a boundary we resynchronize on it directly rather than skipping
         past it.

         [depth] tracks bracket nesting {e entered while skipping}, so a boundary
         that belongs to a construct opened inside the skipped span does not
         resynchronize the enclosing one: an [Open] descends a level, a [Close]
         at depth 0 is a genuine enclosing boundary but otherwise just ascends a
         level, and a [Boundary] (e.g. [";"]) counts only at depth 0. A [Leader]
         (an item/statement-leading keyword) resynchronizes at any depth — an
         unbalanced opener must never swallow the next top-level item, which is
         the whole reason those keywords are boundaries. Always terminates: every
         step that does not stop pulls one token, advancing toward the
         end-of-input [Terminal]. *)
      (* Returns [`Sync tok] (resynchronize on a single token) or, in a
         parenthesized grammar with a [barrier], [`Barrier (toks, pos)] — the
         tokens re-offered to start a new field — when the scan meets the start of
         one at the {e enclosing} level. Two shapes: a bare [(] immediately
         followed by a field keyword (offered as the pair [( ; kw]), or a fused
         [(type]/[(import]/[(export] opener the lexer folds into one token
         (offered alone). Both are honoured only at [depth = 0] — the level of the
         construct being recovered — so a missing closer cannot let depth-counting
         swallow the sibling, while a field-like opener nested in content being
         skipped (a [(func] inside a [(type … (func))] functype) stays ordinary
         content and is descended into, not mistaken for a new field. *)
      let rec find_sync depth tok0 =
        let step ((t, tsp, _) as tok) =
          match sync t with
          | Skip -> find_sync depth None
          | Open -> (
              match barrier with
              | None -> find_sync (depth + 1) None
              | Some (_, is_leader, is_fused) ->
                  if is_fused t then
                    if depth = 0 then `Barrier ([ t ], tsp)
                    else find_sync (depth + 1) None
                  else
                    let ((t2, sp2, _) as tok2) = supplier () in
                    if depth = 0 && is_leader t2 then `Barrier ([ t; t2 ], sp2)
                    else find_sync (depth + 1) (Some tok2))
          | Close -> if depth > 0 then find_sync (depth - 1) None else `Sync tok
          | Boundary -> if depth > 0 then find_sync depth None else `Sync tok
          | Leader | Terminal -> `Sync tok
        in
        match tok0 with Some tok -> step tok | None -> step (supplier ())
      in
      (* [MI.acceptable] answers "can this token make progress?" by driving the
         automaton forward ([shifts] follows reductions via [resume]), so it runs
         the semantic actions of any reduction it passes through — and one of
         those can raise [Syntax_error] (Wax's [process_stmts], a WAT
         pagesize/alignment check). Every use here is a speculative probe during
         recovery, so a raising reduction just means "this token does not lead
         anywhere clean": treat it as not acceptable ([false]) rather than letting
         the raise escape the whole recovery. The error is not recorded — the
         probe was hypothetical; the reduction the user actually reached is
         recorded where it is really performed (in [run] / the outer backstop). *)
      let acceptable checkpoint token pos =
        try MI.acceptable checkpoint token pos with Syntax_error _ -> false
      in
      (* Pop the parser stack to the closest state that could shift [tok] and
         return that env, {e without} offering [tok]. Group-drop uses it to climb
         out of a broken inner group — the state reached is the enclosing context,
         past the group's opener, from which the {e next} boundary (not this
         closer) is resynchronized. [None] if no stacked state accepts [tok]. *)
      let rec pop_to env tok (startp : Lexing.position) =
        if acceptable (MI.input_needed env) tok startp then Some env
        else
          match MI.pop env with
          | Some env' -> pop_to env' tok startp
          | None -> None
      in
      (* Unwind the parser stack to the closest state that can shift [tok] and
         shift it there ([pop_to] then offer), returning the resumed checkpoint;
         [None] if no stacked state accepts it. *)
      let unwind env ((tok, startp, _endp) as sync_tok) =
        match pop_to env tok startp with
        | Some env' -> Some (MI.offer (MI.input_needed env') sync_tok)
        | None -> None
      in
      (* Drive a checkpoint through shifts and reductions to the next decision
         point ([InputNeeded]/[Accepted]/[HandlingError]/[Rejected]). *)
      let rec settle checkpoint =
        match checkpoint with
        | MI.Shifting _ | MI.AboutToReduce _ -> settle (MI.resume checkpoint)
        | _ -> checkpoint
      in
      (* Try to recover by inserting a missing token (typically a statement
         separator [";"]) in front of the offending token, rather than skipping
         to a boundary. When the erroring state can shift [insert] — [acceptable]
         answers this directly, no need to read the error message — offer a
         zero-width [insert] there. But [acceptable] only proves the {e inserted}
         token fits, not that the {e held} (offending) token then does: inserting
         [";"] before an [@] that cannot start a statement would just add a
         spurious "Missing ';'" on top of the real error. So we validate the
         repair by offering the held token on top and requiring that it too be
         consumed — the parser must reach the next [InputNeeded] (held shifted,
         wanting more input) or [Accepted], not an error state. Only a validated
         repair is recorded and returned, with the held token already consumed;
         otherwise [None] falls through to skip-based recovery. Attempted at most
         once per source position ([last_insert]) so it cannot loop. *)
      let try_insert env last =
        match last with
        | Some ((_, startp, _) as held)
          when insert <> [] && !last_insert <> startp.Lexing.pos_cnum ->
            last_insert := startp.Lexing.pos_cnum;
            let cp = MI.input_needed env in
            let insert_pos =
              match MI.top env with
              | Some (MI.Element (_, _, _, pos2)) -> pos2
              | None -> startp
            in
            (* Try each candidate token in order; keep the first that both is
               acceptable and, once the held token is offered on top, leaves the
               parser wanting more input or accepting (the validation check). On a
               validated repair, derive a machine-applicable quick fix
               mechanically from the insertion: a zero-width edit at the caret
               (where the missing token belongs) inserting [new_text], the
               candidate's source spelling from the [insert] configuration. It
               rides on the error [record_missing] flags, so it is attached only
               when the insertion really unblocked the parse — a speculative
               attempt that never validates (see below) produces nothing. *)
            let attempt (tok, message, move_pos, new_text) =
              if not (acceptable cp tok startp) then None
              else
                match settle (MI.offer cp (tok, startp, startp)) with
                | MI.InputNeeded _ as after_insert -> (
                    match settle (MI.offer after_insert held) with
                    | (MI.InputNeeded _ | MI.Accepted _) as after_held ->
                        let caret = if move_pos then insert_pos else startp in
                        let fix =
                          {
                            Wax_utils.Diagnostic.edit_location =
                              { loc_start = caret; loc_end = caret };
                            new_text;
                          }
                        in
                        if move_pos then
                          record_missing ~fix message insert_pos startp
                        else record_missing ~fix message startp startp;
                        Some after_held
                    | _ -> None)
                | _ -> None
            in
            List.find_map attempt insert
        | _ -> None
      in
      (* When the offending token is itself a structural boundary — a closing
         bracket, the statement separator, or EOF — but is rejected because an
         inner construct in front of it is still open, the generic [skip] would
         unwind {e past} that inner construct to a state that accepts the
         boundary, dropping it. E.g. in ["fn f() { add(1, 2 }"] the unclosed
         [add(1, 2] is discarded so [f]'s body is empty, and at EOF the whole
         function the user is still typing is lost. So first try to {e auto-close}
         the inner construct: repeatedly insert whichever [closers] token (or, in
         between, the [insert] separator) the parser will accept until the
         offending token itself becomes acceptable, then offer it — so the inner
         construct reduces into the best-effort AST before the boundary consumes
         it. Returns the resumed checkpoint, or [None] to fall through to [skip].
         The syntax error itself is still recorded by the caller; only the
         recovered AST improves.

         A closer is always preferred; the separator only steps in to end a
         statement that must be terminated before its block can close (e.g.
         ["add(1, 2 }"] needs ")" then ";" then "}"). Termination: every inserted
         closer shifts a closing bracket, which strictly reduces the open-bracket
         nesting, so only finitely many are inserted. The separator would
         otherwise self-loop — a bare ";" is a valid {e empty} statement, so it
         stays acceptable in a statement list forever — so it is allowed only when
         the previous insertion was not itself a separator ([prev_sep]); no two
         separators run consecutively, and a closer or the target must follow.
         [fuel] is a final backstop, not the real bound. *)
      (* Insert acceptable [closers] one at a time — or, when none fits and
         [with_insert] is set, an acceptable [insert] candidate (a statement
         separator, or a placeholder operand that lets a construct complete), but
         never two non-closers in a row — up to [fuel] steps, until [goal
         checkpoint] returns [Some]. Shared by [close_pending] (auto-close a
         construct in front of a boundary, [~with_insert:true]) and [place_field]
         (barrier placement, [~with_insert:false] — closers only). Termination:
         every inserted closer shifts a closing bracket, strictly reducing the
         open-bracket nesting, and no two non-closers run consecutively (a bare
         [";"] is a valid empty statement, so it would otherwise self-loop), so
         only finitely many are inserted; [fuel] is a backstop. [pos] is the
         zero-width position the inserted tokens carry. *)
      let insert_to_goal ~goal ~with_insert pos checkpoint =
        let rec loop checkpoint prev_insert fuel =
          if fuel <= 0 then None
          else
            match goal checkpoint with
            | Some _ as r -> r
            | None -> (
                match
                  List.find_opt (fun c -> acceptable checkpoint c pos) closers
                with
                | Some c ->
                    loop
                      (settle (MI.offer checkpoint (c, pos, pos)))
                      false (fuel - 1)
                | None -> (
                    if (not with_insert) || prev_insert then None
                    else
                      match
                        List.find_opt
                          (fun (tok, _, _, _) -> acceptable checkpoint tok pos)
                          insert
                      with
                      | Some (tok, _, _, _) ->
                          loop
                            (settle (MI.offer checkpoint (tok, pos, pos)))
                            true (fuel - 1)
                      | None -> None))
        in
        loop checkpoint false 1000
      in
      let close_pending env last =
        match (last, closers) with
        | Some ((t, pos, _) as target), _ :: _
          when match sync t with
               | Close | Boundary | Terminal -> true
               | Open | Leader | Skip -> false ->
            insert_to_goal ~with_insert:true pos (MI.input_needed env)
              ~goal:(fun cp ->
                if acceptable cp t pos then Some (settle (MI.offer cp target))
                else None)
        | _ -> None
      in
      (* A fully-parenthesized grammar (WAT) has no separator or leader token, so
         a {e missing closer} — [(module (func (i32.const 1) (func …] — surfaces
         as a field-opening keyword offered where an instruction was expected:
         the [(] before it shifted as a folded-instruction opener, then the
         keyword ([func]) errors. Depth-counting would then swallow the sibling.
         [barrier] names that shape: a token [(] to re-offer and a predicate
         recognizing the keyword. On such an error, pop the spurious [(] off the
         stack ([MI.pop]) and, from the state before it, insert closers until
         re-offering [(] leaves the keyword acceptable (i.e. we have climbed to
         the field level, closing the enclosing construct on the way) — then
         offer [(] and the keyword, so the enclosing field reduces into the AST
         and the new one starts. [None] falls through to [skip]. The two-token
         trial (offer [(], test the keyword) is why a bare "[(] is acceptable"
         check is not enough: [(] is acceptable at every nesting level. *)
      (* Re-offer a barrier pair [( <keyword>] — the start of a new field in a
         parenthesized grammar — from the closest level that accepts it, so the
         enclosing (broken) field reduces into the AST and the new one starts. A
         two-token trial is essential: [(] alone is acceptable at every nesting
         level (it starts a folded instruction), so we must offer [(] then the
         keyword and require the keyword to settle. We reach that level only by
         inserting closers (a {e missing} closer — climb by closing the enclosing
         field, keeping its body), which is value-preserving and fuel-bounded.
         Climbing by [MI.pop] instead would discard the semantic values of any
         construct already reduced onto the stack (a stray [)] that closed a
         module early would lose all its fields), so it is not attempted; when
         insertion cannot reach an accepting level, [None] falls through to
         [skip]. *)
      let place_field env toks pos =
        (* Offer the barrier's tokens in sequence — [( ; <keyword>] for a bare
           opener, or the single fused [(type]/[(import]/[(export] token — from
           the closest level that accepts them, requiring the last to settle to
           [InputNeeded]/[Accepted]. The multi-token trial is why a bare "[(] is
           acceptable" check is not enough: [(] (and a fused opener, valid both as
           a module field and nested) is acceptable at more than one level. *)
        let offer_all checkpoint =
          let rec go cp = function
            | [] -> (
                match cp with
                | MI.InputNeeded _ | MI.Accepted _ -> Some cp
                | _ -> None)
            | tok :: rest -> (
                match cp with
                | MI.InputNeeded _ when acceptable cp tok pos ->
                    go (settle (MI.offer cp (tok, pos, pos))) rest
                | _ -> None)
          in
          go checkpoint toks
        in
        (* Climb by inserting closers (value-preserving, no [insert] candidates)
           until the barrier tokens settle; see [insert_to_goal]. *)
        insert_to_goal ~goal:offer_all ~with_insert:false pos
          (MI.input_needed env)
      in
      (* Direct-error barrier route: the held token is a field keyword whose [(]
         already shifted as a folded-instruction opener (the [(module (func …
         (func …] missing-closer shape). Pop that one cell, then place the pair
         from the state before it. The other route — the barrier met while
         scanning — is handled in [skip] via [find_sync]'s [`Barrier].

         It must only fire on a keyword genuinely written [( keyword]: the token
         offered just before it ([prev]) has to be the bare [(], else popping a
         cell would fabricate a spurious field from a keyword typed bare as an
         instruction ([(func (nop) memory)], where [prev] is [)]). [prev] is the
         exact previous token, so a comment between the [(] and the keyword — which
         a raw-source scan would trip over — is irrelevant. *)
      let try_barrier env prev last =
        match (barrier, prev, last) with
        | Some (lparen, is_leader, _), Some (pt, _, _), Some (t, pos, _)
          when is_leader t && pt = lparen -> (
            match MI.pop env with
            | Some env' -> place_field env' [ lparen; t ] pos
            | None -> None)
        | _ -> None
      in
      (* Main loop: [last] is the most recently offered token, so at a
         [HandlingError] it is the token that provoked the error; [prev] is the
         token offered just before it, which [try_barrier] consults to tell a
         field keyword genuinely written [( keyword] from one typed bare as an
         instruction. *)
      (* Run a speculative repair ([try_insert]/[close_pending]/[try_barrier]/
         [place_field]) and treat a [Syntax_error] it raises as the repair simply
         failing ([None]). Those helpers drive the automaton through [settle],
         whose reductions can re-raise the same check that fires in [run] (e.g.
         when a repair closes a construct); such a raise means only that this
         candidate is not viable, exactly like an unacceptable token. The error is
         NOT recorded: the repair was hypothetical, so flagging a construct the
         user never wrote would be a phantom. A raise from a [run] call is a
         reduction on committed input and is left to [run]'s own catch. *)
      let abandon_on_raise f = try f () with Syntax_error _ -> None in
      let rec run checkpoint prev last =
        match checkpoint with
        | MI.InputNeeded _ ->
            let tok = supplier () in
            run (MI.offer checkpoint tok) last (Some tok)
        | MI.Shifting _ -> run (MI.resume checkpoint) prev last
        | MI.AboutToReduce (env, _) -> (
            (* A grammar semantic action can raise [Syntax_error] as it reduces
               (Wax's [process_stmts] rejecting a dangling [#[else]]; a WAT
               pagesize/alignment/annotation check): the vanilla engine has no
               [error]-production hook, so the raise would otherwise escape [run]
               to the outer backstop and abandon the rest of the file, losing
               every later error. Catch it here and route into the same panic
               machinery a [HandlingError] uses — as if a plain syntax error had
               occurred at the reduction point, except the message comes from the
               exception rather than the parser-messages table.

               Termination hinges on not re-running the reduction that just
               raised. The reduce did not complete, so [env] still carries the
               production's operands and its pending reduce action; recovery
               driving the automaton forward from it (offering a token, then
               reducing) reaches that reduction again and re-raises, which without
               care loops or duplicates the error. So before recovering we
               [defuse] [env]: [last] is the lookahead that triggered the reduce,
               and we pop operand cells off the stack until offering [last] no
               longer reaches the failing reduction, i.e. it can never re-fire.
               [skip] then resynchronizes from that state and consumes further
               input from the supplier. Popping strictly shrinks a finite stack
               and [skip] advances toward end-of-input, so recovery terminates.
               When [last] is itself end-of-input — the start symbol's final
               reduction, the class the outer backstop used to own — there is
               nothing after it to recover: record and stop. *)
            (* Would offering [held] to [env] still reach the failing reduction?
               [MI.acceptable] cannot answer this — it only checks that [held]
               can be shifted and stops at that shift, never driving on to the
               reduction that follows (which is what raises). So drive by hand:
               offer [held] and follow the checkpoints. A reduction that raises
               ([AboutToReduce] resumes into the semantic action) means the
               production is still live. A [Shifting] means [held] would be
               shifted back into an operand slot and could re-complete the
               production, so that too counts as still poisoned. Only when [held]
               is rejected outright ([HandlingError]/[Rejected]) or consumed
               cleanly ([InputNeeded]/[Accepted]) is the production out of
               reach. *)
            let poisoned env (tok, sp, ep) =
              let rec drive cp =
                match cp with
                | MI.Shifting _ -> true
                | MI.AboutToReduce _ -> drive (MI.resume cp)
                | MI.InputNeeded _ | MI.Accepted _ | MI.HandlingError _
                | MI.Rejected ->
                    false
              in
              try drive (MI.offer (MI.input_needed env) (tok, sp, ep))
              with Syntax_error _ -> true
            in
            let rec defuse env held =
              if poisoned env held then
                match MI.pop env with
                | Some env' -> defuse env' held
                | None -> env
              else env
            in
            match MI.resume checkpoint with
            | exception Syntax_error e -> (
                (* Push the full structured payload (keeping any [related]/[hint]/
                   [fix] the semantic action attached), not just location+message. *)
                errors := e :: !errors;
                match last with
                | Some ((t, _, _) as held)
                  when match sync t with Terminal -> false | _ -> true ->
                    skip (defuse env held) last
                | _ -> None)
            | checkpoint -> run checkpoint prev last)
        | MI.HandlingError env -> recover checkpoint env prev last
        | MI.Accepted v -> Some v
        | MI.Rejected -> None
      and recover checkpoint env prev last =
        match abandon_on_raise (fun () -> try_insert env last) with
        | Some checkpoint -> run checkpoint None None
        | None -> (
            (* Insertion did not apply: record the standard error, then either
               auto-close an inner construct still open in front of the boundary
               or skip to a boundary. *)
            record checkpoint;
            match abandon_on_raise (fun () -> close_pending env last) with
            | Some checkpoint -> run checkpoint None None
            | None -> (
                match
                  abandon_on_raise (fun () -> try_barrier env prev last)
                with
                | Some checkpoint -> run checkpoint None None
                | None -> skip env last))
      and skip env last =
        match find_sync 0 last with
        | `Barrier (toks, pos) -> place_barrier env toks pos
        | `Sync ((tok, startp, _) as sync_tok) ->
            (* Group-drop (parenthesized grammars only, hence the [barrier]
               guard): the resync token is a closer [)] that the error state
               cannot itself shift — it closes an {e inner} group whose
               production is still incomplete, e.g. the missing multi-token
               operand of [(v128.const)]. Offering it via [unwind] would climb to
               an ancestor and consume {e that} ancestor's closer instead,
               dropping the enclosing field ([(func (v128.const))] would lose the
               whole [func]). So drop the broken group — pop past its opener and
               discard its closer — and resynchronize on the next boundary, which
               the enclosing construct can then close normally. A closer that the
               error state {e can} shift closes the construct legitimately (junk
               in an otherwise-complete body), so it is offered as before.
               Progresses — a token is consumed — so recovery still terminates.

               Guarded on the source nesting ([paren_depth] minus this closer's
               own contribution, i.e. the openers still enclosing it): group-drop
               is only meaningful when an inner group is genuinely open. A stray
               [)] after an already-complete construct — [(module (func (nop))) )]
               — sits at depth 0 with nothing open, and popping toward it would
               climb into the finished construct and discard it; there it is left
               to [offer_sync], which simply drops it. *)
            let enclosing_depth =
              !paren_depth
              - match sync tok with Open -> 1 | Close -> -1 | _ -> 0
            in
            if
              barrier <> None
              && (match sync tok with Close -> true | _ -> false)
              && enclosing_depth > 0
              && not (acceptable (MI.input_needed env) tok startp)
            then group_drop env tok startp sync_tok
            else offer_sync env sync_tok
      and group_drop env tok startp sync_tok =
        (* Pop past the broken group's opener so the barrier or the next closer
           lands in the enclosing context, not grafted onto the incomplete group
           (e.g. [(import "m")] must not absorb the following [(func …)] as its
           descriptor). If the stack cannot be climbed, fall back to offering the
           closer where the error left us. *)
        match pop_to env tok startp with
        | None -> offer_sync env sync_tok
        | Some env' -> (
            match find_sync 0 None with
            | `Barrier (toks, pos) -> place_barrier env' toks pos
            | `Sync sync_tok -> offer_sync env' sync_tok)
      and place_barrier env toks pos =
        (* A new field starts here: place the barrier tokens, closing the
           enclosing construct as needed. A false barrier makes [place_field]
           fail; drop it and scan on. *)
        match abandon_on_raise (fun () -> place_field env toks pos) with
        | Some checkpoint -> run checkpoint None None
        | None -> skip env None
      and offer_sync env ((tok, _, _) as sync_tok) =
        match unwind env sync_tok with
        | Some checkpoint -> run checkpoint None None
        | None -> (
            (* No stacked state can shift this boundary. At end of input there is
               nothing left to try; otherwise drop this boundary and scan on for
               the next one, keeping the same error state to unwind from. *)
            match sync tok with
            | Terminal -> None
            | _ -> skip env None)
      in
      (* Lexer errors are handled by [recovering_supplier] above (recorded, then
         skipped). [Lexing_gave_up] means it could not make progress, so stop —
         the error is already recorded. The [Syntax_error]/[Sedlexing] arms are a
         backstop for a raise from elsewhere (e.g. a grammar semantic action),
         recorded here since the supplier did not see it. *)
      let start = snd (Sedlexing.lexing_bytes_positions lexbuf) in
      let ast =
        try run (P.Incremental.parse start) None None with
        | Lexing_gave_up -> None
        | Syntax_error e ->
            errors := e :: !errors;
            None
        | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
            let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
            record_error
              { Wax_utils.Ast.loc_start; loc_end }
              (Wax_utils.Message.text
                 "Input file contains malformed UTF-8 byte sequences");
            None
      in
      (ast, List.rev !errors)

    (* Printing variant, as the CLI expects: report the structured error (same
       message and labels) and re-raise via [report_syntax_error]. *)
    let parse_from_string ?color ~filename text =
      match parse_diagnostics ~filename text with
      | Ok ast -> ast
      | Error e -> report_syntax_error ~color text e
  end

  let parse_from_string ?color ~filename text =
    Wax_utils.Debug.timed "parse" @@ fun () ->
    let ctx = Wax_utils.Trivia.make () in
    let module Context = struct
      type t = Wax_utils.Trivia.context

      let context = ctx
    end in
    let module I = Inner (Context) in
    (I.parse_from_string ?color ~filename text, ctx)

  let parse ?color ~filename () =
    parse_from_string ?color ~filename (read filename)

  let parse_diagnostics ~filename text =
    Wax_utils.Debug.timed "parse" @@ fun () ->
    let ctx = Wax_utils.Trivia.make () in
    let module Context = struct
      type t = Wax_utils.Trivia.context

      let context = ctx
    end in
    let module I = Inner (Context) in
    match I.parse_diagnostics ~filename text with
    | Ok ast -> Ok (ast, ctx)
    | Error e -> Error e

  let parse_recover ~filename ~sync ?insert ?closers ?barrier text =
    Wax_utils.Debug.timed "parse" @@ fun () ->
    let ctx = Wax_utils.Trivia.make () in
    let module Context = struct
      type t = Wax_utils.Trivia.context

      let context = ctx
    end in
    let module I = Inner (Context) in
    let ast, errors =
      I.parse_recover ~filename ~sync ?insert ?closers ?barrier text
    in
    (ast, errors, ctx)
end

(* The full parser: {!Make} plus the fast parser, used for its speed on the
   happy path. [parse_from_string] tries the fast parser and, on any failure,
   falls back to the core's incremental [parse_from_string], which re-parses and
   either succeeds or raises the reported syntax error. The fast attempt only
   fails on a syntax error (both parsers accept the same grammar), so the
   fallback always ends in that error; its partial trivia context is therefore
   irrelevant and discarded. *)
module Make_parser (Output : sig
  type t
end) (Tokens : sig
  type token
end) (Parser : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (Fast_parser : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    exception Error

    val parse : (Lexing.lexbuf -> token) -> Lexing.lexbuf -> Output.t
  end
end) (Parser_messages : sig
  val message : int -> string
end) (Lexer : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) =
struct
  module Core = Make (Output) (Tokens) (Parser) (Parser_messages) (Lexer)
  include Core

  let parse_from_string ?color ~filename text =
    Wax_utils.Debug.timed "parse" @@ fun () ->
    let ctx = Wax_utils.Trivia.make () in
    let module Context = struct
      type t = Wax_utils.Trivia.context

      let context = ctx
    end in
    let module F = Fast_parser.Make (Context) in
    let lexbuf = initialize_lexing filename text in
    try
      let supplier =
        lexer_lexbuf_to_supplier (Lexer.token Context.context) lexbuf
      in
      let revised_parser =
        MenhirLib.Convert.Simplified.traditional2revised F.parse
      in
      (revised_parser supplier, ctx)
    with
    | F.Error | Syntax_error _ | Sedlexing.InvalidCodepoint _
    | Sedlexing.MalFormed
    ->
      Core.parse_from_string ?color ~filename text

  let parse ?color ~filename () =
    parse_from_string ?color ~filename (read filename)
end
