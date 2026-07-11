(* Base64 VLQ, the integer encoding used by source-map "mappings". *)
module Vlq64 = struct
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="

  let code_rev =
    let a = Array.make 256 (-1) in
    for i = 0 to String.length alphabet - 1 do
      a.(Char.code alphabet.[i]) <- i
    done;
    a

  let in_alphabet x = code_rev.(Char.code x) <> -1
  let vlq_base_shift = 5

  (* binary: 100000 *)
  let vlq_base = 1 lsl vlq_base_shift

  (* binary: 011111 *)
  let vlq_base_mask = vlq_base - 1

  (* binary: 100000 *)
  let vlq_continuation_bit = vlq_base
  let toVLQSigned v = if v < 0 then (-v lsl 1) + 1 else v lsl 1

  let fromVLQSigned v =
    let is_neg = v land 1 = 1 in
    let shift = v lsr 1 in
    if is_neg then -shift else shift

  let add_char buf x = Buffer.add_char buf alphabet.[x]

  let rec encode' buf x =
    let digit = x land vlq_base_mask in
    let rest = x lsr vlq_base_shift in
    if rest = 0 then add_char buf digit
    else (
      add_char buf (digit lor vlq_continuation_bit);
      encode' buf rest)

  let encode b x =
    let vql = toVLQSigned x in
    encode' b vql

  let encode_l b l = List.iter (encode b) l

  let rec decode' acc s start pos =
    let digit = code_rev.(Char.code s.[pos]) in
    if digit = -1 then invalid_arg "Vlq64.decode'";
    let cont = digit land vlq_continuation_bit = vlq_continuation_bit in
    let digit = digit land vlq_base_mask in
    let acc = acc + (digit lsl ((pos - start) * vlq_base_shift)) in
    if cont then decode' acc s start (succ pos) else (acc, succ pos)

  let decode s p =
    let d, i = decode' 0 s p p in
    (fromVLQSigned d, i)

  let decode_l s ~pos ~len =
    let rec aux pos acc len =
      if len = 0 then List.rev acc
      else if len < 0 then invalid_arg "Vlq64.decode_l"
      else
        let d, i = decode s pos in
        let len = len - (i - pos) in
        aux i (d :: acc) len
    in
    aux pos [] len

  type input = { string : string; mutable pos : int; len : int }

  let rec decode' src s pos len offset i =
    if pos = len then invalid_arg "Vlq64.decode'";
    let digit = Array.unsafe_get code_rev (Char.code s.[pos]) in
    if digit = -1 then invalid_arg "Vlq64.decode'";
    let i = i + ((digit land vlq_base_mask) lsl offset) in
    if digit >= vlq_continuation_bit then
      decode' src s (pos + 1) len (offset + vlq_base_shift) i
    else (
      src.pos <- pos + 1;
      i)

  let decode src = fromVLQSigned (decode' src src.string src.pos src.len 0 0)
end

type t = {
  enabled : bool;
      (* When false, recording is a no-op: [mappings] stays empty, so the whole
         module writer runs without accumulating (and later shifting) one entry
         per instruction — dead work whenever no source map was requested, and a
         stack overflow on a large binary before [shift_since] was made
         tail-recursive. *)
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

let create ~enabled =
  { enabled; files = Hashtbl.create 10; next_file_idx = 0; mappings = [] }

let entry_offset = function Mapped m -> m.generated_offset | Unmapped o -> o

let register_file t filename =
  match Hashtbl.find_opt t.files filename with
  | Some idx -> idx
  | None ->
      let idx = t.next_file_idx in
      Hashtbl.add t.files filename idx;
      t.next_file_idx <- idx + 1;
      idx

let add_mapping_at t ~generated_offset ~(position : Lexing.position) =
  if t.enabled then
    let file_idx = register_file t position.Lexing.pos_fname in
    let line =
      position.Lexing.pos_lnum - 1
      (* 0-indexed *)
    in
    let column =
      position.Lexing.pos_cnum - position.Lexing.pos_bol
      (* 0-indexed *)
    in
    match t.mappings with
    (* A mapping is sticky too: a run of consecutive instructions at the same
       source position needs only its first segment — the rest re-state a
       position that already holds. Skip them, as for [Unmapped] below; offsets
       are monotonic in record order, so this drops exactly the redundant
       segments and shrinks the map without changing what it resolves to. *)
    | Mapped m :: _
      when m.original_file_idx = file_idx
           && m.original_line = line && m.original_column = column ->
        ()
    | _ ->
        let new_mapping =
          {
            generated_offset;
            original_file_idx = file_idx;
            original_line = line;
            original_column = column;
          }
        in
        t.mappings <- Mapped new_mapping :: t.mappings

let add_mapping t ~generated_offset ~original_location =
  add_mapping_at t ~generated_offset ~position:original_location.Ast.loc_start

(* Record that the code at [generated_offset] has no original location, so the
   previous mapping does not bleed into it. *)
let add_absent_mapping t ~generated_offset =
  if t.enabled then
    match t.mappings with
    (* A gap marker is sticky, so a run of consecutive [Unmapped] entries carries
       no more information than its first: [to_json] drops the rest anyway. Skip
       recording them instead — a binary input has no source locations, so every
       instruction would otherwise add one, and the accumulated (then shifted)
       list is what overflowed the stack. Offsets are monotonic in record order,
       so the entry kept here is the same one [to_json]'s dedup would keep, and
       the emitted map is unchanged. Skipping a prepend leaves existing cells
       untouched, so checkpoints stay physical suffixes of [mappings]. *)
    | Unmapped _ :: _ -> ()
    | _ -> t.mappings <- Unmapped generated_offset :: t.mappings

type checkpoint = entry list

(* A checkpoint is the mappings list as it stood at capture time. Since mappings
   are only ever prepended, that list stays a physical suffix of [t.mappings]
   until a shift rebuilds the newer cells — and a shift only rebuilds cells newer
   than its own checkpoint, so an outer checkpoint survives inner shifts. *)
let checkpoint t = t.mappings

let shift_since t (cp : checkpoint) ~delta =
  if delta <> 0 then begin
    (* Rebuild the cells newer than [cp] with their offsets shifted, sharing the
       [cp] suffix unchanged. Tail-recursive (accumulate then [rev_append]) so a
       module with a great many mappings — one per instruction, hundreds of
       thousands in a large binary — does not overflow the stack. *)
    let rec loop acc l =
      if l == cp then List.rev_append acc l
      else
        match l with
        | [] -> List.rev acc
        | Mapped m :: rest ->
            loop
              (Mapped { m with generated_offset = m.generated_offset + delta }
              :: acc)
              rest
        | Unmapped o :: rest -> loop (Unmapped (o + delta) :: acc) rest
    in
    t.mappings <- loop [] t.mappings
  end

let encode_vlq_int n =
  let b = Buffer.create 8 in
  Vlq64.encode b n;
  Buffer.contents b

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
