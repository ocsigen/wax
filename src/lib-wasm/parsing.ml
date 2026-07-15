exception Syntax_error of (Lexing.position * Lexing.position) * string

type syntax_error = {
  location : Wax_utils.Ast.location;
  message : string;
  related : Wax_utils.Diagnostic.label list;
}

type sync_class = Boundary | Terminal | Skip

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

let report_syntax_error ?(related = []) ~color source (loc_start, loc_end) msg =
  let theme = Wax_utils.Diagnostic.get_theme ?color () in
  Wax_utils.Diagnostic.output_error_with_source ~theme ~source ~severity:Error
    ~location:{ loc_start; loc_end } ~related (fun f () ->
      Format.fprintf f "%s" msg);
  (* The diagnostic has been printed; re-raise so the caller decides how to
     terminate rather than exiting the process here. The CLI maps this to exit
     code 128 (rejected input, like a validation or type error, not the
     usage-error code; see the exit-code contract in bin/main.ml), while an
     in-process embedder can catch it instead of having the whole process die. *)
  raise (Syntax_error ((loc_start, loc_end), msg))

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
                      message = (fun f () -> Format.fprintf f "%s" msg);
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
           { location = { Wax_utils.Ast.loc_start; loc_end }; message; related })

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
      | Detailed_error e -> Error e
      | Syntax_error ((loc_start, loc_end), msg) ->
          Error
            {
              location = { Wax_utils.Ast.loc_start; loc_end };
              message = msg;
              related = [];
            }
      | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
          let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
          Error
            {
              location = { Wax_utils.Ast.loc_start; loc_end };
              message = "Input file contains malformed UTF-8 byte sequences\n";
              related = [];
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
    let parse_recover ~filename ~sync ?insert text =
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
        errors := { location; message; related = [] } :: !errors
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
        | Syntax_error ((loc_start, loc_end), message) ->
            record_error { Wax_utils.Ast.loc_start; loc_end } message;
            resume ()
        | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
            let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
            record_error
              { Wax_utils.Ast.loc_start; loc_end }
              "Input file contains malformed UTF-8 byte sequences\n";
            resume ()
      in
      let buffer, supplier = E.wrap_supplier recovering_supplier in
      let record checkpoint =
        let (loc_start, loc_end), message, related =
          build_syntax_error text buffer checkpoint
        in
        errors :=
          { location = { Wax_utils.Ast.loc_start; loc_end }; message; related }
          :: !errors
      in
      (* A missing token, reported as a zero-width caret just before the
         offending token (where the inserted token belongs). *)
      let record_missing label (pos : Lexing.position) =
        errors :=
          {
            location = { Wax_utils.Ast.loc_start = pos; loc_end = pos };
            message = Printf.sprintf "Missing '%s'\n" label;
            related = [];
          }
          :: !errors
      in
      (* Return the token to resynchronize on: the next boundary (or terminal)
         reached by discarding tokens from the supplier. [tok0] is the token
         already in hand (the one that triggered the error, if any); if it is
         itself a boundary we resynchronize on it directly rather than skipping
         past it. Always terminates: every non-boundary pull advances toward the
         end-of-input token, which is a [Terminal]. *)
      let rec find_sync tok0 =
        match tok0 with
        | Some ((t, _, _) as tok) when sync t <> Skip -> tok
        | _ -> (
            let ((t, _, _) as tok) = supplier () in
            match sync t with Skip -> find_sync None | _ -> tok)
      in
      (* Unwind the parser stack to the closest state that can shift [tok] and
         shift it there, returning the resumed checkpoint; [None] if no stacked
         state accepts it. *)
      let rec unwind env ((tok, startp, _endp) as sync_tok) =
        let checkpoint = MI.input_needed env in
        if MI.acceptable checkpoint tok startp then
          Some (MI.offer checkpoint sync_tok)
        else
          match MI.pop env with
          | Some env' -> unwind env' sync_tok
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
        match (insert, last) with
        | Some (tok, label), Some ((_, startp, _) as held)
          when !last_insert <> startp.Lexing.pos_cnum
               && MI.acceptable (MI.input_needed env) tok startp -> (
            last_insert := startp.Lexing.pos_cnum;
            let after_insert =
              settle (MI.offer (MI.input_needed env) (tok, startp, startp))
            in
            match after_insert with
            | MI.InputNeeded _ -> (
                match settle (MI.offer after_insert held) with
                | (MI.InputNeeded _ | MI.Accepted _) as after_held ->
                    record_missing label startp;
                    Some after_held
                | _ -> None)
            | _ -> None)
        | _ -> None
      in
      (* Main loop: [last] is the most recently offered token, so at a
         [HandlingError] it is the token that provoked the error. *)
      let rec run checkpoint last =
        match checkpoint with
        | MI.InputNeeded _ ->
            let tok = supplier () in
            run (MI.offer checkpoint tok) (Some tok)
        | MI.Shifting _ | MI.AboutToReduce _ -> run (MI.resume checkpoint) last
        | MI.HandlingError env -> recover checkpoint env last
        | MI.Accepted v -> Some v
        | MI.Rejected -> None
      and recover checkpoint env last =
        match try_insert env last with
        | Some checkpoint -> run checkpoint None
        | None ->
            (* Insertion did not apply: record the standard error and skip to a
               boundary. *)
            record checkpoint;
            skip env last
      and skip env last =
        let ((tok, _, _) as sync_tok) = find_sync last in
        match unwind env sync_tok with
        | Some checkpoint -> run checkpoint None
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
        try run (P.Incremental.parse start) None with
        | Lexing_gave_up -> None
        | Syntax_error ((loc_start, loc_end), message) ->
            record_error { Wax_utils.Ast.loc_start; loc_end } message;
            None
        | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
            let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
            record_error
              { Wax_utils.Ast.loc_start; loc_end }
              "Input file contains malformed UTF-8 byte sequences\n";
            None
      in
      (ast, List.rev !errors)

    (* Printing variant, as the CLI expects: report the structured error (same
       message and labels) and re-raise via [report_syntax_error]. *)
    let parse_from_string ?color ~filename text =
      match parse_diagnostics ~filename text with
      | Ok ast -> ast
      | Error { location = { loc_start; loc_end }; message; related } ->
          report_syntax_error ~related ~color text (loc_start, loc_end) message
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

  let parse_recover ~filename ~sync ?insert text =
    Wax_utils.Debug.timed "parse" @@ fun () ->
    let ctx = Wax_utils.Trivia.make () in
    let module Context = struct
      type t = Wax_utils.Trivia.context

      let context = ctx
    end in
    let module I = Inner (Context) in
    let ast, errors = I.parse_recover ~filename ~sync ?insert text in
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
