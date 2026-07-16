external capture_stdout : unit -> unit = "wax_pager_capture_stdout"
external flush_captured : unit -> unit = "wax_pager_flush_captured"

let should_use_pager () =
  Unix.isatty Unix.stdout
  && Sys.getenv_opt "TERM" <> Some "dumb"
  && Sys.getenv_opt "NOPAGER" = None

(* [more] is the only pager present on every Windows system. *)
let default_pager = if Sys.win32 then "more" else "less -RFX"

let allows_color () =
  (not (should_use_pager ())) || Sys.getenv_opt "PAGER" <> None || not Sys.win32

let use_native f =
  flush stdout;
  let pager =
    match Sys.getenv_opt "PAGER" with Some p -> p | None -> default_pager
  in
  (* [open_process_out] runs the command through the system shell ([/bin/sh
     -c] on Unix, [cmd /d /c] on Windows) with our terminal as its
     stdout/stderr, and returns a channel onto its stdin; [f] writes there,
     leaving the process's own stdout untouched. *)
  let oc = Unix.open_process_out pager in
  (* Closing [oc] gives the pager end-of-file; wait for the user to quit it
     before exiting, whether [f] returned or exited through a diagnostic. *)
  at_exit (fun () ->
      try ignore (Unix.close_process_out oc) with Sys_error _ -> ());
  (* A pager that quits early makes further writes fail; ignoring SIGPIPE
     turns the lethal signal into the [Sys_error] handled below. Windows has
     no SIGPIPE (the write simply fails). *)
  if not Sys.win32 then Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  try
    f oc;
    exit 0
  with Sys_error msg when msg = "Broken pipe" -> exit 0

let use_node f =
  flush stdout;
  capture_stdout ();
  Fun.protect
    ~finally:(fun () ->
      flush stdout;
      flush_captured ())
    (fun () -> f stdout)

let use f =
  if not (should_use_pager ()) then f stdout
  else
    match Sys.backend_type with
    | Native | Bytecode -> use_native f
    | Other _ -> use_node f
