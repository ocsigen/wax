type t = {
  files : (string, int) Hashtbl.t;
  mutable next_file_idx : int;
  mutable mappings : entry list;
}

(* A source-map segment is either a mapping to an original location, or an
   [Unmapped] marker carrying only a generated offset. The latter emits a
   1-field segment that resets the mapping — a generated position with no
   source — so that a run of instructions without a source location is not
   attributed, by the format's "sticky" rule, to the preceding location. *)
and entry = Mapped of mapping | Unmapped of int

and mapping = {
  generated_offset : int;
  original_file_idx : int;
  original_line : int;
  original_column : int;
}

let create () = { files = Hashtbl.create 10; next_file_idx = 0; mappings = [] }
let entry_offset = function Mapped m -> m.generated_offset | Unmapped o -> o

let register_file t filename =
  match Hashtbl.find_opt t.files filename with
  | Some idx -> idx
  | None ->
      let idx = t.next_file_idx in
      Hashtbl.add t.files filename idx;
      t.next_file_idx <- idx + 1;
      idx

let add_mapping t ~generated_offset ~original_location =
  let file_idx =
    register_file t original_location.Ast.loc_start.Lexing.pos_fname
  in
  let new_mapping =
    {
      generated_offset;
      original_file_idx = file_idx;
      original_line = original_location.Ast.loc_start.Lexing.pos_lnum - 1;
      (* 0-indexed *)
      original_column =
        original_location.Ast.loc_start.Lexing.pos_cnum
        - original_location.Ast.loc_start.Lexing.pos_bol;
      (* 0-indexed *)
    }
  in
  t.mappings <- Mapped new_mapping :: t.mappings

(* Record that the code at [generated_offset] has no original location, so the
   previous mapping does not bleed into it. *)
let add_absent_mapping t ~generated_offset =
  t.mappings <- Unmapped generated_offset :: t.mappings

(* Base64 VLQ encoding for source maps: each 5-bit group is emitted low bits
   first, with bit 6 (0x20) marking a continuation, and the resulting 6-bit
   value indexes the base64 alphabet. *)
let base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let encode_vlq_int n =
  let n' = ref (if n < 0 then (abs n lsl 1) lor 1 else n lsl 1) in
  let result = ref [] in
  while !n' <> 0 || !result = [] do
    let digit = !n' land 0x1F in
    n' := !n' lsr 5;
    if !n' <> 0 then result := base64.[digit lor 0x20] :: !result
    else result := base64.[digit] :: !result
  done;
  List.rev !result |> List.to_seq |> String.of_seq

(* A JSON string literal (quoted and escaped) — file names may contain
   backslashes or other characters that must not appear raw in the JSON. *)
let json_string s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let to_json t ~file_name =
  let sorted_mappings =
    List.sort (fun a b -> compare (entry_offset a) (entry_offset b)) t.mappings
  in
  (* An [Unmapped] segment only matters right after a mapping (to close it): a
     leading one, or one following another [Unmapped], resets nothing, so drop
     it to keep the map minimal. *)
  let sorted_mappings =
    let rec dedup acc last = function
      | [] -> List.rev acc
      | Unmapped _ :: rest when last <> `Mapped -> dedup acc last rest
      | (Unmapped _ as e) :: rest -> dedup (e :: acc) `Unmapped rest
      | (Mapped _ as e) :: rest -> dedup (e :: acc) `Mapped rest
    in
    dedup [] `Unmapped sorted_mappings
  in

  let files_list =
    Hashtbl.fold (fun f_name f_idx acc -> (f_idx, f_name) :: acc) t.files []
    |> List.sort (fun (idx_a, _) (idx_b, _) -> compare idx_a idx_b)
    |> List.map snd
  in

  let mappings_string =
    let prev_gen_col = ref 0 in
    let prev_orig_file_idx = ref 0 in
    let prev_orig_line = ref 0 in
    let prev_orig_col = ref 0 in

    List.fold_left
      (fun acc entry ->
        (* For WebAssembly the generated position is a single byte offset into
           the code, encoded as the segment's "column" with an implicit line 0. *)
        let segment =
          match entry with
          | Unmapped generated_offset ->
              (* A 1-field segment: generated position with no source. Only the
                 generated column advances; the source deltas carry over. *)
              let s = encode_vlq_int (generated_offset - !prev_gen_col) in
              prev_gen_col := generated_offset;
              s
          | Mapped mapping ->
              let s =
                String.concat ""
                  [
                    encode_vlq_int (mapping.generated_offset - !prev_gen_col);
                    encode_vlq_int
                      (mapping.original_file_idx - !prev_orig_file_idx);
                    encode_vlq_int (mapping.original_line - !prev_orig_line);
                    encode_vlq_int (mapping.original_column - !prev_orig_col);
                  ]
              in
              prev_gen_col := mapping.generated_offset;
              prev_orig_file_idx := mapping.original_file_idx;
              prev_orig_line := mapping.original_line;
              prev_orig_col := mapping.original_column;
              s
        in
        segment :: acc)
      [] sorted_mappings
    |> List.rev |> String.concat ","
  in

  Printf.sprintf
    {|{
  "version": 3,
  "file": %s,
  "sourceRoot": "",
  "sources": [%s],
  "sourcesContent": [],
  "names": [],
  "mappings": "%s"
}|}
    (json_string file_name)
    (String.concat "," (List.map json_string files_list))
    mappings_string
