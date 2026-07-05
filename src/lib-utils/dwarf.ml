let build_debug_str producer name comp_dir =
  let b = Buffer.create 128 in
  let add_str s =
    let offset = Buffer.length b in
    Buffer.add_string b s;
    Buffer.add_char b '\x00';
    offset
  in
  let producer_offset = add_str producer in
  let name_offset = add_str name in
  let comp_dir_offset = add_str comp_dir in
  (Buffer.contents b, producer_offset, name_offset, comp_dir_offset)

let build_debug_abbrev () =
  let b = Buffer.create 32 in
  let byte b c = Buffer.add_char b c in
  (* Abbrev code = 1 *)
  byte b '\x01';
  (* Tag = DW_TAG_compile_unit = 0x11 *)
  byte b '\x11';
  (* DW_children_no = 0x00 *)
  byte b '\x00';
  (* Attribute specifications *)
  (* DW_AT_producer = 0x25, DW_FORM_strp = 0x0e *)
  byte b '\x25';
  byte b '\x0e';
  (* DW_AT_name = 0x03, DW_FORM_strp = 0x0e *)
  byte b '\x03';
  byte b '\x0e';
  (* DW_AT_comp_dir = 0x1b, DW_FORM_strp = 0x0e *)
  byte b '\x1b';
  byte b '\x0e';
  (* DW_AT_low_pc = 0x11, DW_FORM_addr = 0x01 *)
  byte b '\x11';
  byte b '\x01';
  (* DW_AT_stmt_list = 0x10, DW_FORM_sec_offset = 0x17 *)
  byte b '\x10';
  byte b '\x17';
  (* Terminate attributes *)
  byte b '\x00';
  byte b '\x00';
  (* Terminate abbreviation declarations *)
  byte b '\x00';
  Buffer.contents b

let build_debug_info ~producer_offset ~name_offset ~comp_dir_offset =
  let b = Buffer.create 64 in
  let add_uint32 v =
    Buffer.add_char b (Char.chr (v land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 8) land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 16) land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 24) land 0xff))
  in
  let add_uint16 v =
    Buffer.add_char b (Char.chr (v land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 8) land 0xff))
  in
  (* unit_length: size of CU following this field.
     Size of CU = 2 (version) + 4 (abbrev_offset) + 1 (addr_size) + 1 (abbrev_code) + 5 * 4 (attributes) = 28 bytes *)
  add_uint32 28;
  (* version = 4 *)
  add_uint16 4;
  (* abbrev_offset = 0 *)
  add_uint32 0;
  (* address_size = 4 *)
  Buffer.add_char b '\x04';
  (* abbrev_code = 1 *)
  Buffer.add_char b '\x01';
  (* producer_offset *)
  add_uint32 producer_offset;
  (* name_offset *)
  add_uint32 name_offset;
  (* comp_dir_offset *)
  add_uint32 comp_dir_offset;
  (* low_pc = 0 *)
  add_uint32 0;
  (* stmt_list = 0 *)
  add_uint32 0;
  Buffer.contents b

let build_debug_line ~source_map ~code_payload_start ~func_layouts =
  let b = Buffer.create 1024 in
  let byte i = Buffer.add_char b (Char.chr i) in
  let add_uint32 v =
    Buffer.add_char b (Char.chr (v land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 8) land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 16) land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 24) land 0xff))
  in
  let add_uint16 v =
    Buffer.add_char b (Char.chr (v land 0xff));
    Buffer.add_char b (Char.chr ((v lsr 8) land 0xff))
  in
  let rec uleb128 i =
    if i < 128 then byte i
    else (
      byte (128 + (i land 127));
      uleb128 (i lsr 7))
  in
  let rec sleb128 i =
    if i >= -64 && i < 64 then byte (i land 127)
    else (
      byte (128 + (i land 127));
      sleb128 (i asr 7))
  in

  (* 1. unit_length placeholder *)
  let unit_length_offset = Buffer.length b in
  add_uint32 0;

  (* 2. version = 4 *)
  add_uint16 4;

  (* 3. header_length placeholder *)
  let header_length_offset = Buffer.length b in
  add_uint32 0;

  let header_start = Buffer.length b in

  (* 4. minimum_instruction_length = 1 *)
  byte 1;
  (* 5. maximum_operations_per_instruction = 1 *)
  byte 1;
  (* 6. default_is_stmt = 1 *)
  byte 1;
  (* 7. line_base = -5 (signed byte, 251 or 0xfb) *)
  byte 0xfb;
  (* 8. line_range = 14 *)
  byte 14;
  (* 9. opcode_base = 13 *)
  byte 13;
  (* 10. standard_opcode_lengths *)
  List.iter byte [ 0; 1; 1; 1; 1; 0; 0; 0; 1; 0; 0; 1 ];

  (* 11. include_directories: empty *)
  byte 0;

  (* 12. file_names *)
  let files = Source_map.files source_map in
  List.iter
    (fun f_name ->
      Buffer.add_string b f_name;
      byte 0;
      (* null-terminator *)
      uleb128 0;
      (* directory index *)
      uleb128 0;
      (* mod time *)
      uleb128 0 (* file size *))
    files;
  byte 0;
  (* terminate file names list *)
  let header_end = Buffer.length b in
  let header_len = header_end - header_start in

  (* 13. Line program instructions *)
  (* [Source_map] records file-absolute generated offsets; a function owns the
     entries whose offset falls within its body, and their body-relative offset
     gives the DWARF row address once shifted by the function's start. *)
  let entries = Source_map.entries source_map in

  (* Get the sorted list of function indices from func_layouts *)
  let sorted_func_idxs =
    Hashtbl.fold (fun f_idx _ acc -> f_idx :: acc) func_layouts []
    |> List.sort compare
  in

  let current_file = ref 1 in
  let current_line = ref 1 in
  let current_col = ref 0 in
  let current_addr = ref 0 in

  List.iter
    (fun f_idx ->
      match Hashtbl.find_opt func_layouts f_idx with
      | None -> ()
      | Some (body_start, body_size) ->
          (* Bucket the file-absolute mappings into this body, tagging each with
             its body-relative offset. *)
          let f_entries =
            List.filter_map
              (fun entry ->
                let abs =
                  match entry with
                  | Source_map.Mapped m -> m.generated_offset
                  | Source_map.Unmapped o -> o
                in
                if abs >= body_start && abs < body_start + body_size then
                  Some (abs - body_start, entry)
                else None)
              entries
          in
          let func_start_addr = body_start - code_payload_start in
          let func_end_addr = func_start_addr + body_size in

          if f_entries <> [] then (
            (* Sort entries by offset *)
            let f_entries =
              List.sort (fun (a, _) (b, _) -> compare a b) f_entries
            in

            List.iter
              (fun (offset, entry) ->
                let file_idx, line, col =
                  match entry with
                  | Source_map.Mapped m ->
                      ( Some m.original_file_idx,
                        m.original_line + 1,
                        m.original_column )
                  | Source_map.Unmapped _ -> (None, 0, 0)
                in
                let target_addr = func_start_addr + offset in

                (* 1. Set file *)
                (match file_idx with
                | Some f_idx_0 ->
                    let target_file = f_idx_0 + 1 in
                    if target_file <> !current_file then (
                      byte 4;
                      (* DW_LNS_set_file *)
                      uleb128 target_file;
                      current_file := target_file)
                | None -> ());

                (* 2. Set column *)
                let target_col = if col > 0 then col + 1 else 0 in
                if target_col <> !current_col then (
                  byte 5;
                  (* DW_LNS_set_column *)
                  uleb128 target_col;
                  current_col := target_col);

                (* 3. Set line *)
                if line <> !current_line then (
                  byte 3;
                  (* DW_LNS_advance_line *)
                  sleb128 (line - !current_line);
                  current_line := line);

                (* 4. Set address *)
                if target_addr <> !current_addr then (
                  byte 2;
                  (* DW_LNS_advance_pc *)
                  uleb128 (target_addr - !current_addr);
                  current_addr := target_addr);

                (* 5. Copy row *)
                byte 1)
              f_entries;

            (* End sequence *)
            if func_end_addr <> !current_addr then (
              byte 2;
              (* DW_LNS_advance_pc *)
              uleb128 (func_end_addr - !current_addr);
              current_addr := func_end_addr);
            byte 0;
            uleb128 1;
            byte 1;

            (* Reset register state tracking *)
            current_file := 1;
            current_line := 1;
            current_col := 0;
            current_addr := 0))
    sorted_func_idxs;

  let b_bytes = Buffer.to_bytes b in
  let set_uint32_at offset v =
    let c0 = Char.chr (v land 0xff) in
    let c1 = Char.chr ((v lsr 8) land 0xff) in
    let c2 = Char.chr ((v lsr 16) land 0xff) in
    let c3 = Char.chr ((v lsr 24) land 0xff) in
    Bytes.set b_bytes offset c0;
    Bytes.set b_bytes (offset + 1) c1;
    Bytes.set b_bytes (offset + 2) c2;
    Bytes.set b_bytes (offset + 3) c3
  in
  set_uint32_at header_length_offset header_len;
  let total_len = Bytes.length b_bytes in
  let unit_len = total_len - 4 in
  set_uint32_at unit_length_offset unit_len;
  Bytes.to_string b_bytes

let generate ~source_map ~code_payload_start ~func_layouts ~source_filename =
  let source_filename =
    if source_filename = "" then "main.wax" else source_filename
  in
  let str_bytes, producer_offset, name_offset, comp_dir_offset =
    build_debug_str "wax" source_filename "."
  in
  let abbrev_bytes = build_debug_abbrev () in
  let info_bytes =
    build_debug_info ~producer_offset ~name_offset ~comp_dir_offset
  in
  let line_bytes =
    build_debug_line ~source_map ~code_payload_start ~func_layouts
  in
  [
    (".debug_abbrev", abbrev_bytes);
    (".debug_info", info_bytes);
    (".debug_str", str_bytes);
    (".debug_line", line_bytes);
  ]
