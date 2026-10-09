(* Usage: link_filter OUTPUT EXPORT[,EXPORT...] NAME:FILE...

   Link the Wasm modules [FILE] (imported under module name [NAME]) into
   [OUTPUT], keeping only the listed exports, without removing dead code: the
   [wax link] command keeps all exports. *)

let () =
  match Array.to_list Sys.argv with
  | _ :: output_file :: exports :: inputs ->
      let exports = String.split_on_char ',' exports in
      let inputs =
        List.map
          (fun s ->
            match String.index_opt s ':' with
            | None -> failwith ("bad input " ^ s)
            | Some i ->
                {
                  Wax_linker.Wasm_link.module_name = String.sub s 0 i;
                  file = String.sub s (i + 1) (String.length s - i - 1);
                  code = None;
                  opt_source_map = None;
                })
          inputs
      in
      ignore
        (Wax_linker.Wasm_link.f
           ~rename_export:(fun _ nm ->
             if List.mem nm exports then Some nm else None)
           inputs ~output_file
          : Wax_linker.Source_map.t)
  | _ -> failwith "usage: link_filter OUTPUT EXPORTS NAME:FILE..."
