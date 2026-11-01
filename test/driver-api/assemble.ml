(* Assemble a WAT or Wax module with the embedding API.
   Usage: assemble [--require-string-type] [-D name=true|false]... file *)

let () =
  let require_string_type = ref false in
  let defines = ref [] in
  let file = ref None in
  Arg.parse
    [
      ("--require-string-type", Arg.Set require_string_type, "");
      ( "-D",
        Arg.String
          (fun s ->
            match String.split_on_char '=' s with
            | [ n; v ] ->
                defines := (n, Wax.Define.Bool (bool_of_string v)) :: !defines
            | _ -> raise (Arg.Bad s)),
        "" );
    ]
    (fun f -> file := Some f)
    "assemble";
  let filename = Option.get !file in
  let text = In_channel.with_open_bin filename In_channel.input_all in
  let defines = Wax.Define.of_list !defines in
  let require_string_type = !require_string_type in
  let _ : Wax.binary_module =
    if Filename.check_suffix filename ".wax" then
      Wax.wax_to_binary ~defines ~require_string_type ~filename text
    else Wax.wat_to_binary ~defines ~require_string_type ~filename text
  in
  print_endline "ok"
