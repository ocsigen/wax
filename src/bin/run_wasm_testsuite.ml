(*
- fix remaining issues
- try to convert non-validating code to test more failure cases
- round-trip through wasx syntax
- Somehow checks that round-tripping yield the identity
  (on unfolded code without identifiers?)
*)

let wasm_only = ref false
let color = ref Wax_utils.Colors.Always
let all_errors = ref false
let feature_specs = ref []
let dir_args = ref []

let () =
  let speclist =
    [
      ("--wasm-only", Arg.Set wasm_only, "Generate WebAssembly output only");
      ("--no-color", Arg.Unit (fun () -> color := Never), "Disable color output");
      ( "--all-errors",
        Arg.Unit (fun () -> all_errors := true),
        "Output all errors" );
      ( "--enable",
        Arg.String
          (fun s ->
            match Wax_utils.Feature.parse_spec s with
            | Ok spec -> feature_specs := !feature_specs @ [ spec ]
            | Error e -> raise (Arg.Bad e)),
        "Enable/disable an optional feature (e.g. custom-descriptors)" );
    ]
  in
  Arg.parse speclist
    (fun arg -> dir_args := !dir_args @ [ arg ])
    "Usage: run_wasm_testsuite [options] [dir ...]";
  Wax_utils.Feature.set_config !feature_specs

let print_flushed s =
  print_string s;
  flush stdout

type pending_process = {
  pid : int;
  output_file : string;
  on_termination : bool -> string -> unit;
}

type process_pool = {
  max_concurrent : int;
  mutable running : pending_process list;
}

let create_pool max_concurrent = { max_concurrent; running = [] }
let read_file filename = In_channel.with_open_bin filename In_channel.input_all

(* [In_channel.input_lines] only exists since OCaml 5.1; read lines by hand so
   the test runner still builds on the 4.14 the packages support. *)
let input_lines ic =
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  loop []

let handle_finished_pid pool pid status =
  match List.find_opt (fun proc -> proc.pid = pid) pool.running with
  | Some proc ->
      let success = match status with Unix.WEXITED 0 -> true | _ -> false in
      let output_content = read_file proc.output_file in
      (try Sys.remove proc.output_file with _ -> ());
      pool.running <- List.filter (fun p -> p.pid <> pid) pool.running;
      proc.on_termination success output_content
  | None -> ()

let rec reap_children pool mode =
  match Unix.waitpid mode (-1) with
  | 0, _ -> () (* WNOHANG returned 0: No changes, stop recursing. *)
  | pid, status ->
      handle_finished_pid pool pid status;
      reap_children pool [ Unix.WNOHANG ]
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> pool.running <- []
  | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      (* System call interrupted (e.g. signal), retry exactly as we were *)
      reap_children pool mode

let wait_for_slot pool =
  reap_children pool [ Unix.WNOHANG ];
  if List.length pool.running >= pool.max_concurrent then reap_children pool []

let in_child_process_async pool ?(quiet = false) ~on_termination f =
  wait_for_slot pool;
  let output_file = Filename.temp_file "child_output_" ".txt" in
  match Unix.fork () with
  | 0 ->
      (* Child *)
      let output_fd =
        Unix.openfile output_file
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o600
      in
      Unix.dup2 output_fd Unix.stdout;
      if quiet then (
        let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o666 in
        Unix.dup2 dev_null Unix.stderr;
        Unix.close dev_null)
      else Unix.dup2 output_fd Unix.stderr;
      Unix.close output_fd;
      f ();
      exit 0
  | pid ->
      (* Parent *)
      let proc = { pid; output_file; on_termination } in
      pool.running <- proc :: pool.running

let wait_all_children pool =
  while pool.running <> [] do
    reap_children pool []
  done

let in_child_process ?(quiet = false) f =
  match Unix.fork () with
  | 0 ->
      if quiet then (
        let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o666 in
        Unix.dup2 dev_null Unix.stderr;
        Unix.close dev_null);
      f ();
      exit 0
  | pid ->
      (* Parent process *)
      let _, status = Unix.waitpid [] pid in
      status = Unix.WEXITED 0

let counter = ref 0
let outputs = ref []

(* A per-corpus blacklist: an optional [<root>/blacklist] file listing tests to
   skip, one per line, [#]-comments and blank lines ignored. An entry is either a
   path relative to the corpus root, a directory prefix (trailing [/], skips the
   whole subtree), or a bare basename (matches that file in any subdirectory).
   Prefer this over a hardcoded skip for anything static — only feature-dependent
   skips need to stay in code. *)
let read_blacklist root =
  let file = Filename.concat root "blacklist" in
  if not (Sys.file_exists file) then fun _ -> false
  else
    let entries =
      In_channel.with_open_text file input_lines
      |> List.filter_map (fun line ->
          let line =
            match String.index_opt line '#' with
            | Some i -> String.sub line 0 i
            | None -> line
          in
          let line = String.trim line in
          if line = "" then None else Some line)
    in
    let matches path entry =
      let n = String.length entry in
      if n > 0 && entry.[n - 1] = '/' then
        String.length path >= n && String.sub path 0 n = entry
      else if String.contains entry '/' then path = entry
      else Filename.basename path = entry
    in
    fun path -> List.exists (matches path) entries

let iter_files dirs skip suffix ~output f =
  let pool = create_pool (Domain.recommended_domain_count ()) in
  let rec visit blacklisted root dir =
    let entries = Sys.readdir (Filename.concat root dir) in
    Array.sort compare entries;
    Array.iter
      (fun entry ->
        let path = Filename.concat dir entry in
        if not (blacklisted path || skip path) then
          let full_path = Filename.concat root path in
          if Sys.is_directory full_path then visit blacklisted root path
          else if Filename.check_suffix entry suffix then (
            let i = !counter in
            incr counter;
            in_child_process_async pool
              ~on_termination:(fun _ s -> outputs := (i, path, s) :: !outputs)
              (fun () -> f full_path path)))
      entries
  in
  List.iter (fun root -> visit (read_blacklist root) root "") dirs;
  wait_all_children pool;
  List.iter (fun (_, path, s) -> output path s) (List.sort compare !outputs)

type script =
  ([ `Valid | `Invalid of string | `Malformed of string ]
  * [ `Parsed of Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    | `Text of string
    | `Binary of string ])
  list

module Script_parser = struct
  module Make (Context : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    module P = Wax_wasm.Parser.Make (Context)

    type token = Wax_wasm.Tokens.token

    module MenhirInterpreter = P.MenhirInterpreter

    module Incremental = struct
      let parse pos = P.Incremental.parse_script pos
    end
  end
end

module Fast_script_parser = struct
  module Make (Context : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    module F = Wax_wasm.Fast_parser.Make (Context)

    type token = Wax_wasm.Tokens.token

    exception Error = F.Error

    let parse lexer lexbuf = F.parse_script lexer lexbuf
  end
end

module ModuleParser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
    end)
    (Wax_wasm.Tokens)
    (Wax_wasm.Parser)
    (Wax_wasm.Fast_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

module ScriptParser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = script
    end)
    (Wax_wasm.Tokens)
    (Script_parser)
    (Fast_script_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

module WaxParser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Fast_parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

let print_module ~color f m =
  let trivia = Wax_utils.Trivia.empty () in
  Wax_utils.Printer.run f (fun p -> Wax_wasm.Output.module_ p ~color ~trivia m)

let contains_substring s sub =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    i + m <= n && (String.equal (String.sub s i m) sub || loop (i + 1))
  in
  m = 0 || loop 0

(* Parse a Wasm binary. On malformed input the diagnostic is rendered into a
   string (via [run ~exit:false], which flushes and re-raises [Aborted] instead
   of exiting the process) and returned as [Error text]; the caller decides
   whether to print it and how to check it against the expected reason. *)
let parse_binary ~color ?filename txt =
  let buf = Buffer.create 256 in
  let output = Format.formatter_of_buffer buf in
  match
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:None ~exit:false ~output (fun d ->
        Wax_wasm.Wasm_parser.module_ d ?filename txt)
  with
  | m -> Ok m
  | exception Wax_utils.Diagnostic.Aborted ->
      Format.pp_print_flush output ();
      Error (Buffer.contents buf)

let runtest filename _ =
  let quiet = not !all_errors in
  let color = !color in
  let source = In_channel.with_open_bin filename In_channel.input_all in
  let lst, _ctx = ScriptParser.parse_from_string ~color ~filename source in
  let lst = List.map (fun (status, m) -> (status, m, Some source)) lst in
  (* Parsing *)
  let lst =
    List.filter_map
      (fun (status, m, source) ->
        match (status, m) with
        | ((`Valid | `Invalid _) as status), `Parsed m ->
            Some (status, m, source)
        | ((`Valid | `Invalid _) as status), `Text txt ->
            Some
              ( status,
                ModuleParser.parse_from_string ~color ~filename txt |> fst,
                Some txt )
        | ((`Valid | `Invalid _) as status), `Binary txt -> (
            match parse_binary ~color ~filename txt with
            | Error rendered ->
                Format.eprintf "Parsing failed unexpectedly: %s@.%s"
                  (String.escaped txt) rendered;
                None
            | Ok binary_ast ->
                let m = Wax_wasm.Binary_to_text.module_ binary_ast in
                (*
            Format.eprintf "%a@." (print_module ~color:!color) m;
*)
                Some (status, m, None))
        | `Malformed _, `Parsed _ -> assert false
        | `Malformed reason, `Text txt ->
            let ok =
              in_child_process ~quiet (fun () ->
                  let ast, _ctx =
                    ModuleParser.parse_from_string ~color ~filename txt
                  in
                  Wax_utils.Diagnostic.run ~color
                    ~palette:Wax_utils.Colors.wat_theme ~source:(Some txt)
                    (fun d -> Wax_wasm.Validation.f ~warn_unused:false d ast);
                  if false then
                    Format.printf "@[<2>Result:@ %a@]@." (print_module ~color)
                      ast)
            in
            if ok then
              Format.eprintf "Parsing should have failed (%s): %s@." reason txt;
            None
        | `Malformed reason, `Binary txt -> (
            match parse_binary ~color ~filename txt with
            | Error rendered ->
                (* Parsing failed, as expected. Under [--all-errors] show the
                   diagnostic, and flag it when our message does not match the
                   spec's expected reason. *)
                if not quiet then (
                  Format.eprintf "%s" rendered;
                  if not (contains_substring rendered reason) then
                    Format.eprintf
                      "  message diverges from expected reason: %s@." reason);
                None
            | Ok binary_ast ->
                let ast = Wax_wasm.Binary_to_text.module_ binary_ast in
                let ok =
                  in_child_process ~quiet (fun () ->
                      Wax_utils.Diagnostic.run ~color
                        ~palette:Wax_utils.Colors.wat_theme ~source:(Some txt)
                        (fun d ->
                          Wax_wasm.Validation.f ~warn_unused:false d ast);
                      if false then
                        Format.printf "@[<2>Result:@ %a@]@."
                          (print_module ~color) ast)
                in
                if ok then
                  Format.eprintf "Parsing should have failed (%s): %s@." reason
                    (String.escaped txt);
                None))
      lst
  in
  (* Serialization and reparsing *)
  let lst' =
    List.map
      (fun (status, m, _) ->
        let text = Format.asprintf "%a@." (print_module ~color:Never) m in
        if false then print_flushed text;
        ( status,
          ModuleParser.parse_from_string ~color ~filename text |> fst,
          Some text ))
      lst
  in
  (* Serialization and reparsing (Wasm) *)
  let lst'' =
    if false then []
    else
      List.filter_map
        (fun (status, m, _) ->
          match status with
          | `Invalid _ -> None
          | `Valid -> (
              if false then (
                prerr_endline " BEFORE";
                Format.eprintf "@[%a@]@." (print_module ~color) m
                (*if false then prerr_endline (String.escaped text)*));
              let temp, out_channel =
                Filename.open_temp_file ~mode:[ Open_binary ] "temp" ".wasm"
              in
              Wax_wasm.Wasm_output.module_ ~out_channel
                (Wax_wasm.Text_to_binary.module_ m);
              close_out out_channel;
              let text = read_file temp in
              Sys.remove temp;
              match parse_binary ~color text with
              | Error rendered ->
                  Format.eprintf "Reparsing serialized binary failed:@.%s"
                    rendered;
                  None
              | Ok binary_ast ->
                  let m = Wax_wasm.Binary_to_text.module_ binary_ast in
                  if false then (
                    prerr_endline "AFTER ";
                    Format.eprintf "@[%a@]@." (print_module ~color) m);
                  Some (status, m, None)))
        lst
  in
  (* Validation. The wasm validator is run over every variant (the originals,
     the modules reparsed from printed text and from the serialized binary),
     reporting any module that should have been rejected but was not. *)
  List.iter
    (fun (status, m, source) ->
      match (status, m) with
      | `Valid, m ->
          if false then Format.eprintf "@[%a@]@." (print_module ~color) m;
          Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
            ~source (fun d -> Wax_wasm.Validation.f ~warn_unused:false d m)
      | `Invalid reason, m ->
          let ok =
            in_child_process ~quiet (fun () ->
                (* Under [--all-errors], print the spec's expected reason just
                   before validation reports its own message, so the two can be
                   compared (validation [exit]s at the first error, so we cannot
                   capture and check it in the parent the way we do for malformed
                   binaries). *)
                if not quiet then Format.eprintf "Expected reason: %s@." reason;
                Wax_utils.Diagnostic.run ~color
                  ~palette:Wax_utils.Colors.wat_theme ~source (fun d ->
                    Wax_wasm.Validation.f ~warn_unused:false d m);
                if false then
                  Format.printf "@[<2>Result:@ %a@]@." (print_module ~color) m)
          in
          if ok then
            Format.eprintf "@[<2>Validation should have failed (%s):@ %a@]@."
              reason (print_module ~color) m)
    (lst @ lst' @ lst'');
  (* The translation phase keeps every valid variant, but only the original
     copy of each invalid module: the reparsed variants would just repeat the
     same wax check. *)
  let lst =
    lst @ List.filter (fun (status, _, _) -> status = `Valid) lst' @ lst''
  in
  (* Translation to new syntax *)
  let print_wax ~color f m =
    Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
        Wax_lang.Output.module_ ~color p ~trivia:(Wax_utils.Trivia.empty ()) m)
  in
  List.iter
    (fun (status, wasm_m, source) ->
      if not !wasm_only then
        (* For an invalid module, cast every numeric constant to its concrete
           type so a source-level type mismatch is not hidden by Wax inference
           re-typing an otherwise polymorphic literal. *)
        let strict_constants =
          match status with `Invalid _ -> true | `Valid -> false
        in
        match
          Wax_conversion.From_wasm.module_ ~strict_constants
            (Wax_utils.Diagnostic.collector ())
            wasm_m
        with
        | exception
            (( Wax_conversion.From_wasm.Unresolved_reference _
             | Wax_utils.Diagnostic.Aborted ) as e) -> (
            (* On an invalid module, conversion legitimately gives up: an
               out-of-range / undeclared reference, or a type-invalid construct
               it cannot represent (which it reports and aborts on). Surface it
               only if it somehow happens on a module that should convert. *)
            match status with
            | `Invalid _ -> ()
            | `Valid -> prerr_endline (Printexc.to_string e))
        | exception e ->
            prerr_endline (Printexc.to_string e);
            if false then Format.eprintf "@[%a@]@." (print_module ~color) wasm_m
        | m -> (
            match status with
            | `Invalid reason ->
                (* The wasm module is invalid; after translating it to wax,
                   printing and reparsing, wax type-checking should reject it
                   too. *)
                let text = Format.asprintf "%a@." (print_wax ~color:Never) m in
                let ok =
                  in_child_process ~quiet (fun () ->
                      let m', _ctx =
                        WaxParser.parse_from_string ~color ~filename text
                      in
                      Wax_utils.Diagnostic.run ~color
                        ~palette:Wax_utils.Colors.wax_theme ~source:(Some text)
                        (fun d -> Wax_lang.Typing.check d m'))
                in
                if ok then
                  Format.eprintf
                    "@[<2>Wax type-checking should have failed (%s):@ %a@]@,\
                     @[<2>from wasm:@ %a@]@."
                    reason (print_wax ~color) m (print_module ~color) wasm_m
            | `Valid ->
                let ok =
                  in_child_process (fun () ->
                      (* Simplify the converted module — dropping casts the
                         precise types make redundant — exactly as the CLI's
                         wasm->wax path does, so the round-trip and validation
                         below exercise the [simplify] pass. *)
                      let _, m =
                        Wax_utils.Diagnostic.run ~color
                          ~palette:Wax_utils.Colors.wax_theme ~source (fun d ->
                            Wax_lang.Typing.f ~simplify:true d m)
                      in
                      let types, m =
                        Wax_utils.Diagnostic.run ~color
                          ~palette:Wax_utils.Colors.wax_theme ~source (fun d ->
                            Wax_lang.Typing.f d (Wax_lang.Typing.erase_types m))
                      in
                      let m' =
                        Wax_utils.Diagnostic.run ~color
                          ~palette:Wax_utils.Colors.wax_theme ~source (fun d ->
                            Wax_conversion.To_wasm.module_ d types m)
                      in
                      let ok =
                        in_child_process (fun () ->
                            Wax_utils.Diagnostic.run ~color
                              ~palette:Wax_utils.Colors.wat_theme ~source
                              (fun d ->
                                Wax_wasm.Validation.f ~warn_unused:false d m'))
                      in
                      if not ok then (
                        Format.eprintf "@[%a@]@." (print_module ~color) m';
                        Format.eprintf "@[%a@]@." (print_wax ~color)
                          (Wax_lang.Typing.erase_types m)))
                in
                if not ok then Format.eprintf "@[%a@]@." (print_wax ~color) m;
                let text = Format.asprintf "%a@." (print_wax ~color:Never) m in
                let ok =
                  in_child_process (fun () ->
                      let m', _ctx =
                        WaxParser.parse_from_string ~color ~filename text
                      in
                      if true then
                        let ok =
                          in_child_process (fun () ->
                              Wax_utils.Diagnostic.run ~color
                                ~palette:Wax_utils.Colors.wax_theme
                                ~source:(Some text) (fun d ->
                                  Wax_lang.Typing.check d m'))
                        in
                        if not ok then
                          if false then prerr_endline "(after parsing)"
                          else (
                            Format.eprintf "@[%a@]@." (print_wax ~color) m';
                            prerr_endline "===";
                            Format.eprintf "@[%a@]@." (print_wax ~color) m))
                in
                if not ok then
                  if true then prerr_endline "(parsing)" else print_flushed text
            ))
    lst

let output path s =
  if s <> "" then (
    Format.printf "%s==== %s ====%s@."
      (match !color with Always -> Wax_utils.Colors.Ansi.grey | _ -> "")
      path
      (match !color with Always -> Wax_utils.Colors.Ansi.reset | _ -> "");
    print_flushed s)

(* The directories to walk for [.wast] files: the ones named on the command
   line, or the built-in spec suite when none are given. A separate golden (e.g.
   the vendored wasm-tools corpus) is produced by passing its dir explicitly. *)
let dirs =
  match !dir_args with
  | [] -> [ "wasm-test-suite"; "additional-tests" ]
  | l -> l

let custom_descriptors_on =
  Wax_utils.Feature.is_enabled
    (Wax_utils.Feature.default ())
    Wax_utils.Feature.Custom_descriptors

(* Feature-dependent skips (static ones live in each corpus's [blacklist] file):
   the custom-descriptors tests only make sense with the feature enabled; the
   pre-proposal [gc/br_on_cast*] tests, conversely, conflict with the relaxed
   branching-cast typing the proposal introduces (same-hierarchy casts they
   assert invalid become valid), so they are skipped when it is on. *)
let skip path =
  let base = Filename.basename path in
  (contains_substring path "custom-descriptors" && not custom_descriptors_on)
  || custom_descriptors_on
     && Filename.basename (Filename.dirname path) = "gc"
     && List.mem base [ "br_on_cast.wast"; "br_on_cast_fail.wast" ]

let () = iter_files dirs ~output skip ".wast" runtest
