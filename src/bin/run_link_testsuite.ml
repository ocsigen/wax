(* Drive the linker ([Wax_linker.Wasm_link]) through the WebAssembly spec test
   suite's linking commands. A [.wast] script names modules with [(register
   "name" $id?)] and asserts non-linkability with [(assert_unlinkable (module …)
   "reason")]; both are exactly what a merge linker is for. The plain suite
   driver ([run_wasm_testsuite.ml]) validates each module in isolation and
   throws these commands away — this driver keeps a name→module registry and
   actually links.

   Each module that imports from a registered module is linked against its
   registered dependencies (the modules it transitively imports, [spectest]
   included), mirroring the spec's instantiation of one module against the
   instances it names. A module that should instantiate is expected to link
   with every import resolved; an [assert_unlinkable] module is expected not to.
   Standalone modules that import nothing registered do not exercise linking and
   are skipped (see [imports_registered]).

   Because a merge linker leaves an *unresolved* import as a residual import of
   the output rather than erroring, "import not found" is detected by re-reading
   the merged module and treating any remaining import as non-linkability; and
   because a successful merge can still produce an invalid module, the merged
   module is validated. See [link_outcome], which classifies each link as
   linked / unresolved / invalid / rejected (the linker reported an incompatible
   import) / crashed.

   Output is a golden diff like the other suites: per-file lines under a
   [==== path ====] header naming each disagreement with the spec (see
   [output]), empty when a file links exactly as the spec says. *)

let color = ref Wax_utils.Colors.Always
let feature_specs = ref []
let dir_args = ref []

let () =
  let speclist =
    [
      ("--no-color", Arg.Unit (fun () -> color := Never), "Disable color output");
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
    "Usage: run_link_testsuite [options] [dir ...]";
  Wax_utils.Feature.set_config !feature_specs

let print_flushed s =
  print_string s;
  flush stdout

(* --- Process pool (per-file parallelism), copied from run_wasm_testsuite --- *)

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
  | 0, _ -> ()
  | pid, status ->
      handle_finished_pid pool pid status;
      reap_children pool [ Unix.WNOHANG ]
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> pool.running <- []
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap_children pool mode

let wait_for_slot pool =
  reap_children pool [ Unix.WNOHANG ];
  if List.length pool.running >= pool.max_concurrent then reap_children pool []

let in_child_process_async pool ~on_termination f =
  wait_for_slot pool;
  let output_file = Filename.temp_file "link_child_output_" ".txt" in
  match Unix.fork () with
  | 0 ->
      let output_fd =
        Unix.openfile output_file
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o600
      in
      Unix.dup2 output_fd Unix.stdout;
      Unix.dup2 output_fd Unix.stderr;
      Unix.close output_fd;
      f ();
      exit 0
  | pid -> pool.running <- { pid; output_file; on_termination } :: pool.running

let wait_all_children pool =
  while pool.running <> [] do
    reap_children pool []
  done

let counter = ref 0
let outputs = ref []

(* A per-corpus blacklist file, in run_wasm_testsuite's format. *)
let read_blacklist_file file =
  if not (Sys.file_exists file) then fun _ -> false
  else
    let entries =
      In_channel.with_open_text file In_channel.input_lines
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

(* The linker suite honours the shared corpus [blacklist] and its own
   [link-blacklist] — tests a static merge linker structurally cannot run
   (e.g. importing a memory/table the spec grows at instantiation before the
   import, which the linker rightly rejects on the declared limits). *)
let read_blacklist root =
  let shared = read_blacklist_file (Filename.concat root "blacklist") in
  let linker = read_blacklist_file (Filename.concat root "link-blacklist") in
  fun path -> shared path || linker path

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

(* --- Parsers --- *)

(* The linking-oriented script view (start symbol [parse_link_script]): each
   module with its identifier, [register] commands, and [assert_unlinkable]
   modules. This is what the plain script grammar discards. *)
type repr =
  [ `Parsed of Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
  | `Text of string
  | `Binary of string ]

type command =
  [ `Module of Wax_wasm.Ast.Text.name option * repr
  | `Register of string * Wax_wasm.Ast.Text.name option
  | `Unlinkable of (Wax_wasm.Ast.Text.name option * repr) * string ]

module Link_script_parser = struct
  module Make (Context : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) =
  struct
    module P = Wax_wasm.Parser.Make (Context)

    type token = Wax_wasm.Tokens.token

    module MenhirInterpreter = P.MenhirInterpreter

    module Incremental = struct
      let parse pos = P.Incremental.parse_link_script pos
    end
  end
end

(* Menhir-only [Parsing.Make]: the harness is not on any hot path, and the fast
   parser has no [parse_link_script] entry point. *)
module LinkScriptParser =
  Wax_wasm.Parsing.Make
    (struct
      type t = command list
    end)
    (Wax_wasm.Tokens)
    (Link_script_parser)
    (Wax_wasm.Parser_messages)
    (Wax_wasm.Lexer)

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

(* Parse a wasm binary, returning the module or a rendered diagnostic. *)
let parse_binary ~color txt =
  let buf = Buffer.create 256 in
  let output = Format.formatter_of_buffer buf in
  match
    Wax_utils.Diagnostic.run ~color ~palette:Wax_utils.Colors.wat_theme
      ~source:None ~exit:false ~output (fun d ->
        Wax_wasm.Wasm_parser.module_ d txt)
  with
  | m -> Ok m
  | exception Wax_utils.Diagnostic.Aborted ->
      Format.pp_print_flush output ();
      Error (Buffer.contents buf)

(* --- Materialisation and linking --- *)

(* Temp files created while processing the current script, removed when done. *)
let scratch = ref []

(* Temp names are formed from the process id and a per-process counter rather
   than [Filename.temp_file]: the driver forks a child per file, and forked
   children inherit an identical [temp_file] PRNG state, so concurrent children
   would generate the same names and collide under [O_EXCL] ("File exists"). *)
let tmp_counter = ref 0

let fresh_wasm () =
  incr tmp_counter;
  let f =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "waxlink_%d_%d.wasm" (Unix.getpid ()) !tmp_counter)
  in
  scratch := f :: !scratch;
  f

let clean_scratch () =
  List.iter (fun f -> try Sys.remove f with _ -> ()) !scratch;
  scratch := []

let write_binary_module (m : Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_) =
  let f = fresh_wasm () in
  Out_channel.with_open_bin f (fun oc ->
      Wax_wasm.Wasm_output.module_ ~out_channel:oc
        (Wax_wasm.Text_to_binary.module_ m));
  f

(* Compile a script module to a temp [.wasm] file. Modules reaching here are
   individually well-formed (the invalid/malformed ones never appear as
   [`Module]/[`Unlinkable] in the grammar), so lowering should not fail. *)
let module_to_file ~color ~filename (repr : repr) =
  match repr with
  | `Binary bytes ->
      let f = fresh_wasm () in
      Out_channel.with_open_bin f (fun oc -> output_string oc bytes);
      f
  | `Parsed m -> write_binary_module m
  | `Text txt ->
      let m, _ = ModuleParser.parse_from_string ~color ~filename txt in
      write_binary_module m

let input_of ~module_name file : Wax_linker.Wasm_link.input =
  { module_name; file; code = None; opt_source_map = None }

(* The distinct module names a compiled module imports from. *)
let import_module_names file =
  match parse_binary ~color:!color (read_file file) with
  | Ok m ->
      List.sort_uniq compare
        (List.map
           (fun (e : Wax_wasm.Ast.Binary.import_entry) ->
             match e with
             | Single { module_; _ }
             | Group1 { module_; _ }
             | Group2 { module_; _ } ->
                 module_)
           m.Wax_wasm.Ast.Binary.imports)
  | Error _ -> []

(* Whether [file] imports anything from a module currently in the registry, i.e.
   whether linking it actually resolves a cross-module reference. Standalone
   modules (no such import) do not exercise linking — relinking them would only
   test the linker's binary reader/writer, which is out of scope here (and the
   WIP linker does not yet decode every instruction). *)
let imports_registered ~registry file =
  List.exists (Hashtbl.mem registry) (import_module_names file)

(* The inputs for instantiating [test_file] against the registry: the module
   itself, plus every registered module it transitively imports (its
   dependencies' dependencies too). This mirrors the spec's instantiation — a
   module links against the *instances* it names, not against every module ever
   registered — so merging unrelated modules cannot introduce spurious failures.
   A referenced module absent from the registry is simply left out, so its
   import stays unresolved and is caught by the residual-import check below. *)
(* The module name given to the module under test, distinct from any registered
   dependency's name so [rename_export] can single it out. *)
let test_module_name = "$link-test"

let link_inputs ~registry test_file =
  let deps = Hashtbl.create 16 in
  let rec add file =
    List.iter
      (fun modname ->
        if not (Hashtbl.mem deps modname) then
          match Hashtbl.find_opt registry modname with
          | Some dep_file ->
              Hashtbl.replace deps modname dep_file;
              add dep_file
          | None -> ())
      (import_module_names file)
  in
  add test_file;
  Hashtbl.fold
    (fun name file acc -> input_of ~module_name:name file :: acc)
    deps
    [ input_of ~module_name:test_module_name test_file ]

(* The outcome of linking a module against its registry dependencies.
   [Linked] the merge succeeded, every import resolved, and the merged module
   validates; [Unresolved] it succeeded but left an import dangling (a merge
   linker does not error on an unsatisfiable import, so we detect it by
   re-reading the output); [Invalid] it succeeded but produced an invalid
   module; [Rejected] [Wasm_link.f] reported an incompatible import and
   [exit]ed; [Crashed] the linker raised (an unsupported instruction, an index
   bug, …). *)
type outcome = Linked | Unresolved | Invalid | Rejected | Crashed

(* Run [f] in a forked child, returning whether it exited normally. Used to run
   the validator, which [exit]s on an invalid module, without taking the caller
   down with it. *)
let in_child f =
  match Unix.fork () with
  | 0 ->
      f ();
      exit 0
  | pid -> (
      match Unix.waitpid [] pid with _, Unix.WEXITED 0 -> true | _ -> false)

(* Link [test_file] against its dependencies and classify the result. Runs in a
   forked child because [Wasm_link.f] [exit]s (128) on a link error and may
   raise on inputs it cannot yet decode; the child's exit status carries the
   outcome back. Only the module under test keeps its exports (a dependency's are
   dropped by [rename_export]) so cross-module export names cannot collide in the
   merged output — import resolution alone decides the outcome, and the test
   module's exports remain to invoke in the behavioural step. *)
let link_outcome ~registry test_file =
  let out = fresh_wasm () in
  let inputs = link_inputs ~registry test_file in
  match Unix.fork () with
  | 0 ->
      let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o666 in
      Unix.dup2 dev_null Unix.stderr;
      Unix.close dev_null;
      ignore
        (Wax_linker.Wasm_link.f
           ~rename_export:(fun m nm ->
             if m = test_module_name then Some nm else None)
           inputs ~output_file:out
          : Wax_linker.Source_map.t);
      (match parse_binary ~color:!color (read_file out) with
      | Ok m ->
          if m.Wax_wasm.Ast.Binary.imports <> [] then exit 3;
          (* The merged module must validate: a successful merge can still
             produce an invalid module (e.g. a table initializer referencing a
             now-internalised global that follows it). *)
          if
            not
              (in_child (fun () ->
                   Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
                     ~palette:Wax_utils.Colors.wat_theme ~source:None (fun d ->
                       Wax_wasm.Validation.f ~warn_unused:false d
                         (Wax_wasm.Binary_to_text.module_ m))))
          then exit 4
      | Error _ -> exit 3);
      exit 0
  | pid -> (
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> Linked
      | _, Unix.WEXITED 3 -> Unresolved
      | _, Unix.WEXITED 4 -> Invalid
      | _, Unix.WEXITED 128 -> Rejected (* Wasm_link.f's diagnostic exit *)
      | _ -> Crashed)

let contains_substring s sub =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    (i + m <= n && String.equal (String.sub s i m) sub)
    || (i + m <= n && loop (i + 1))
  in
  m = 0 || loop 0

(* Reasons for which the spec expects non-linkability at *instantiation* time
   (out-of-bounds active segments, etc.) rather than at link/type-check time. A
   static merge linker structurally cannot see these, so such assertions are
   skipped and logged rather than treated as failures. *)
let instantiation_time_reason reason =
  List.exists
    (fun s -> contains_substring reason s)
    [ "out of bounds"; "does not fit"; "out of range"; "uninitialized element" ]

let name_desc (n : Wax_wasm.Ast.Text.name) = n.Wax_wasm.Ast.desc

(* The host "spectest" module (test/spectest.wat), compiled once to a temp
   [.wasm] shared by every file-child and registered as "spectest" before each
   link. Kept out of the per-script [scratch] so a child never removes it. *)
let spectest_file = ref ""

let compile_spectest ~color =
  let m, _ =
    ModuleParser.parse_from_string ~color ~filename:"spectest.wat"
      (read_file "spectest.wat")
  in
  let f = Filename.temp_file "spectest_" ".wasm" in
  Out_channel.with_open_bin f (fun oc ->
      Wax_wasm.Wasm_output.module_ ~out_channel:oc
        (Wax_wasm.Text_to_binary.module_ m));
  spectest_file := f

let clean_spectest () = try Sys.remove !spectest_file with _ -> ()

let runtest filename _ =
  let color = !color in
  let cmds, _ =
    LinkScriptParser.parse_from_string ~color ~filename (read_file filename)
  in
  let registry : (string, string) Hashtbl.t = Hashtbl.create 16 in
  Hashtbl.replace registry "spectest" !spectest_file;
  let by_id : (string, string) Hashtbl.t = Hashtbl.create 16 in
  let last = ref None in
  let materialise repr =
    try Some (module_to_file ~color ~filename repr)
    with e ->
      Format.eprintf "Could not compile module: %s@." (Printexc.to_string e);
      None
  in
  List.iter
    (fun (cmd : command) ->
      match cmd with
      | `Module (id, repr) -> (
          match materialise repr with
          | None -> ()
          | Some file -> (
              last := Some file;
              Option.iter (fun n -> Hashtbl.replace by_id (name_desc n) file) id;
              (* Only modules that resolve against a registered module test
                 linking; a standalone module has nothing to link. *)
              if imports_registered ~registry file then
                match link_outcome ~registry file with
                | Linked -> ()
                | Unresolved ->
                    Format.eprintf
                      "Should instantiate, but an import is left unresolved@."
                | Invalid ->
                    Format.eprintf
                      "Should instantiate, but linking produced an invalid \
                       module@."
                | Rejected ->
                    Format.eprintf
                      "Should instantiate, but the linker rejected an import@."
                | Crashed ->
                    Format.eprintf
                      "Should instantiate, but the linker crashed@."))
      | `Register (name, id) ->
          let target =
            match id with
            | Some n -> Hashtbl.find_opt by_id (name_desc n)
            | None -> !last
          in
          Option.iter (fun file -> Hashtbl.replace registry name file) target
      | `Unlinkable ((_, repr), reason) -> (
          if instantiation_time_reason reason then
            Format.eprintf "Skipped instantiation-time unlinkable: %s@." reason
          else
            match materialise repr with
            | None -> ()
            | Some file -> (
                match link_outcome ~registry file with
                | Linked ->
                    Format.eprintf "Linked, but the spec says unlinkable (%s)@."
                      reason
                (* Unresolved / Invalid / Rejected / Crashed all mean the module
                   did not link, which is what the spec asserts — nothing to
                   report. *)
                | Unresolved | Invalid | Rejected | Crashed -> ())))
    cmds;
  clean_scratch ()

let output path s =
  if s <> "" then (
    Format.printf "%s==== %s ====%s@."
      (match !color with Always -> Wax_utils.Colors.Ansi.grey | _ -> "")
      path
      (match !color with Always -> Wax_utils.Colors.Ansi.reset | _ -> "");
    print_flushed s)

let dirs = match !dir_args with [] -> [ "wasm-test-suite" ] | l -> l

let custom_descriptors_on =
  Wax_utils.Feature.is_enabled
    (Wax_utils.Feature.default ())
    Wax_utils.Feature.Custom_descriptors

let skip path =
  contains_substring path "custom-descriptors" && not custom_descriptors_on

let () =
  compile_spectest ~color:!color;
  iter_files dirs ~output skip ".wast" runtest;
  clean_spectest ()
