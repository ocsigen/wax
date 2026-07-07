exception Syntax_error of (Lexing.position * Lexing.position) * string

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
  val token : Wax_utils.Trivia.context -> Sedlexing.lexbuf -> Tokens.token
end) =
struct
  module E = MenhirLib.ErrorReports
  module Lu = MenhirLib.LexerUtil

  let succeed v = v

  let show text positions =
    E.extract text positions |> E.sanitize |> E.compress
    |> E.shorten 20 (* max width 43 *)

  let report_syntax_error ?(related = []) ~color source (loc_start, loc_end) msg
      =
    let theme = Wax_utils.Diagnostic.get_theme ?color () in
    Wax_utils.Diagnostic.output_error_with_source ~theme ~source ~severity:Error
      ~location:{ loc_start; loc_end } ~related (fun f () ->
        Format.fprintf f "%s" msg);
    (* A syntax error is a rejected input, like a validation or type error, so
       it shares their exit code (128) rather than the usage-error code. See
       the exit-code contract in bin/main.ml. *)
    exit 128

  let read filename = In_channel.with_open_bin filename In_channel.input_all

  let initialize_lexing filename text =
    let lexbuf = Sedlexing.Utf8.from_string text in
    Sedlexing.set_filename lexbuf filename;
    lexbuf

  let lexer_lexbuf_to_supplier lexer (lexbuf : Sedlexing.lexbuf) () =
    let token = lexer lexbuf in
    let startp, endp = Sedlexing.lexing_bytes_positions lexbuf in
    (token, startp, endp)

  module Inner (Context : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    module P = Parser.Make (Context)
    module F = Fast_parser.Make (Context)

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

    let fail ~color text buffer checkpoint =
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
                  (* This hint points at an opening delimiter, and should
                     underline just the single '('/'['/'{' character. The stack
                     token's own span is not it: WAT's [(then]/[(param]/… lex the
                     keyword as one token whose span starts *after* the '(', and
                     a spurious reduction can even surface a token just past the
                     delimiter. In every such case the delimiter sits immediately
                     before the token (modulo blanks) on the same line, so scan
                     the source back to it; fall back to the token start. *)
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
      report_syntax_error ~related:related_labels ~color text location message

    let parse_from_string ?color ~filename text =
      let lexbuf = initialize_lexing filename text in
      try
        let supplier =
          lexer_lexbuf_to_supplier (Lexer.token Context.context) lexbuf
        in
        let revised_parser =
          MenhirLib.Convert.Simplified.traditional2revised F.parse
        in
        revised_parser supplier
      with
      | F.Error ->
          let lexbuf = initialize_lexing filename text in
          let supplier =
            lexer_lexbuf_to_supplier (Lexer.token Context.context) lexbuf
          in
          let buffer, supplier = E.wrap_supplier supplier in
          let checkpoint =
            P.Incremental.parse (snd (Sedlexing.lexing_bytes_positions lexbuf))
          in
          P.MenhirInterpreter.loop_handle succeed (fail ~color text buffer)
            supplier checkpoint
      | Syntax_error (loc, msg) -> report_syntax_error ~color text loc msg
      | Sedlexing.InvalidCodepoint _ | Sedlexing.MalFormed ->
          report_syntax_error text ~color
            (Sedlexing.lexing_bytes_positions lexbuf)
            "Input file contains malformed UTF-8 byte sequences\n"
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
end
