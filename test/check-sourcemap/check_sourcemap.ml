open Wax_linker

type mapping = {
  gen_col : int;
  src_file : int option;
  src_line : int option;
  src_col : int option;
  src_name : int option;
}

let decode_mappings mappings_str =
  let segments = String.split_on_char ',' mappings_str in
  let gen_col = ref 0 in
  let src_file = ref 0 in
  let src_line = ref 0 in
  let src_col = ref 0 in
  let src_name = ref 0 in
  let decoded = ref [] in
  List.iter
    (fun segment ->
      if segment <> "" then
        let fields =
          Vlq64.decode_l segment ~pos:0 ~len:(String.length segment)
        in
        match fields with
        | [ g ] ->
            gen_col := !gen_col + g;
            decoded :=
              {
                gen_col = !gen_col;
                src_file = None;
                src_line = None;
                src_col = None;
                src_name = None;
              }
              :: !decoded
        | g :: f :: l :: c :: rest ->
            gen_col := !gen_col + g;
            src_file := !src_file + f;
            src_line := !src_line + l;
            src_col := !src_col + c;
            let n =
              match rest with
              | [ name_idx ] ->
                  src_name := !src_name + name_idx;
                  Some !src_name
              | _ -> None
            in
            decoded :=
              {
                gen_col = !gen_col;
                src_file = Some !src_file;
                src_line = Some !src_line;
                src_col = Some !src_col;
                src_name = n;
              }
              :: !decoded
        | _ -> ())
    segments;
  List.rev !decoded

let read_file filename =
  let ch = open_in_bin filename in
  let len = in_channel_length ch in
  let buf = really_input_string ch len in
  close_in ch;
  buf

type parsed_section = {
  offset : int;
  sources : string list;
  names : string list;
  mappings : mapping list;
}

let parse_standard_map json =
  let open Yojson.Safe.Util in
  let sources = json |> member "sources" |> to_list |> List.map to_string in
  let names = json |> member "names" |> to_list |> List.map to_string in
  let mappings_str = json |> member "mappings" |> to_string in
  let mappings = decode_mappings mappings_str in
  (sources, names, mappings)

let parse_index_map filename =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_file filename in
  let sections = json |> member "sections" |> to_list in
  List.map
    (fun sect ->
      let offset = sect |> member "offset" |> member "column" |> to_int in
      let map_json = sect |> member "map" in
      let sources, names, mappings = parse_standard_map map_json in
      { offset; sources; names; mappings })
    sections

let find_index pred list =
  let rec loop idx = function
    | [] -> None
    | x :: xs -> if pred x then Some idx else loop (idx + 1) xs
  in
  loop 0 list

let () =
  if Array.length Sys.argv < 4 then (
    Printf.eprintf
      "Usage: %s <output_wasm> <output_map> <input_wasm_1> [<input_wasm_2> ...]\n"
      Sys.argv.(0);
    exit 1);
  let output_wasm = Sys.argv.(1) in
  let output_map = Sys.argv.(2) in
  let inputs =
    List.init (Array.length Sys.argv - 3) (fun i -> Sys.argv.(3 + i))
  in

  let output_buf = read_file output_wasm in
  let output_offsets, _ =
    Wasm_link.get_instruction_offsets ~filename:output_wasm output_buf
  in

  let parsed_sections = parse_index_map output_map in
  if List.length parsed_sections <> List.length inputs then (
    Printf.eprintf
      "Error: output map has %d sections, but %d inputs were provided\n"
      (List.length parsed_sections)
      (List.length inputs);
    exit 1);

  let global_instr_idx = ref 0 in
  List.iter2
    (fun input_wasm section ->
      let input_buf = read_file input_wasm in
      let input_offsets, _ =
        Wasm_link.get_instruction_offsets ~filename:input_wasm input_buf
      in

      let input_map_file = input_wasm ^ ".map" in
      (if Sys.file_exists input_map_file then
         let input_map_json = Yojson.Safe.from_file input_map_file in
         let sources, names, input_mappings =
           parse_standard_map input_map_json
         in

         List.iter
           (fun input_m ->
             match
               find_index (fun pos -> pos = input_m.gen_col) input_offsets
             with
             | None ->
                 Printf.eprintf
                   "Warning: input mapping at %d in %s is not on instruction \
                    boundary\n"
                   input_m.gen_col input_wasm
             | Some local_idx -> (
                 let expected_output_col =
                   List.nth output_offsets (!global_instr_idx + local_idx)
                 in
                 let rel_expected_col = expected_output_col - section.offset in
                 match
                   List.find_opt
                     (fun m -> m.gen_col = rel_expected_col)
                     section.mappings
                 with
                 | None ->
                     Printf.eprintf
                       "Error: mapping for instruction %d in %s (input offset \
                        %d, expected output offset %d) not found in output \
                        source map\n"
                       local_idx input_wasm input_m.gen_col expected_output_col;
                     exit 1
                 | Some output_m ->
                     let get_opt_val arr idx_opt =
                       Option.map (List.nth arr) idx_opt
                     in
                     let input_src = get_opt_val sources input_m.src_file in
                     let output_src =
                       get_opt_val section.sources output_m.src_file
                     in
                     if input_src <> output_src then (
                       Printf.eprintf
                         "Error: source mismatch for input offset %d: expected \
                          %s, got %s\n"
                         input_m.gen_col
                         (Option.value ~default:"None" input_src)
                         (Option.value ~default:"None" output_src);
                       exit 1);
                     if
                       input_m.src_line <> output_m.src_line
                       || input_m.src_col <> output_m.src_col
                     then (
                       Printf.eprintf
                         "Error: line/col mismatch for input offset %d\n"
                         input_m.gen_col;
                       exit 1);
                     let input_name = get_opt_val names input_m.src_name in
                     let output_name =
                       get_opt_val section.names output_m.src_name
                     in
                     if input_name <> output_name then (
                       Printf.eprintf
                         "Error: name mismatch for input offset %d: expected \
                          %s, got %s\n"
                         input_m.gen_col
                         (Option.value ~default:"None" input_name)
                         (Option.value ~default:"None" output_name);
                       exit 1)))
           input_mappings);

      List.iter
        (fun output_m ->
          let abs_col = section.offset + output_m.gen_col in
          if not (List.mem abs_col output_offsets) then (
            Printf.eprintf
              "Error: output mapping at offset %d points inside an instruction\n"
              abs_col;
            exit 1))
        section.mappings;

      global_instr_idx := !global_instr_idx + List.length input_offsets)
    inputs parsed_sections;

  Printf.printf "Instruction-boundary source map verification successful!\n"
