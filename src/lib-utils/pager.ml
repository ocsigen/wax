external capture_stdout : unit -> unit = "wax_pager_capture_stdout"
external flush_captured : unit -> unit = "wax_pager_flush_captured"

let should_use_pager () =
  Unix.isatty Unix.stdout
  && Sys.getenv_opt "TERM" <> Some "dumb"
  && Sys.getenv_opt "NOPAGER" = None

let use_native f =
  flush stdout;
  let read_fd, write_fd = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close write_fd;
      Unix.dup2 read_fd Unix.stdin;
      Unix.close read_fd;
      let shell = "/bin/sh" in
      let pager =
        match Sys.getenv_opt "PAGER" with Some p -> p | _ -> "less -RFX"
      in
      Unix.execv shell [| shell; "-c"; pager |]
  | pid -> (
      Unix.close read_fd;
      Unix.dup2 write_fd Unix.stdout;
      Unix.close write_fd;
      at_exit (fun () ->
          Unix.close Unix.stdout;
          ignore (Unix.waitpid [] pid));
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      try
        f ();
        exit 0
      with Sys_error msg when msg = "Broken pipe" -> exit 0)

let use_node f =
  flush stdout;
  capture_stdout ();
  Fun.protect
    ~finally:(fun () ->
      flush stdout;
      flush_captured ())
    (fun () -> f ())

let use f =
  if not (should_use_pager ()) then f ()
  else
    match Sys.backend_type with
    | Native | Bytecode -> use_native f
    | Other _ -> use_node f
