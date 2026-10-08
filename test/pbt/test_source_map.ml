open Wax_linker.Source_map
module Vlq64 = Wax_utils.Source_map.Vlq64

(* Naive reference implementation. Structurally independent of the streaming
   [resize_mappings] (split on ',', full [decode_l] per segment) but with the
   same specification, including folding a dropped segment's source/original
   fields into the next survivor that emits them, and emitting a segment
   without origin at the start of a [drop] range whose segments were dropped
   when the last segment emitted before it has an origin. *)
let naive_resize_mappings ?(drop = []) resize_data mappings =
  if mappings = "" || (resize_data.i = 0 && drop = []) then mappings
  else
    let segments = String.split_on_char ',' mappings in
    let shift_at col =
      let shift = ref 0 in
      for k = 0 to resize_data.i - 1 do
        if resize_data.pos.(k) <= col then
          shift := !shift + resize_data.delta.(k)
      done;
      !shift
    in
    let col_acc = ref 0 in
    let new_col_acc = ref 0 in
    let pending_source = ref 0 in
    let pending_line = ref 0 in
    let pending_col = ref 0 in
    let pending_name = ref 0 in
    let output = ref [] in
    let last_has_origin = ref false in
    let ranges = ref drop in
    let range_dropped = ref false in
    let emit new_col tail =
      let buf = Buffer.create 16 in
      Vlq64.encode buf (new_col - !new_col_acc);
      new_col_acc := new_col;
      last_has_origin := tail <> [];
      (match tail with
      | [] -> ()
      | source :: line :: column :: rest -> (
          Vlq64.encode buf (source + !pending_source);
          Vlq64.encode buf (line + !pending_line);
          Vlq64.encode buf (column + !pending_col);
          pending_source := 0;
          pending_line := 0;
          pending_col := 0;
          match rest with
          | [] -> ()
          | name :: rest ->
              Vlq64.encode buf (name + !pending_name);
              pending_name := 0;
              List.iter (Vlq64.encode buf) rest)
      | fields -> List.iter (Vlq64.encode buf) fields);
      output := Buffer.contents buf :: !output
    in
    let close_range () =
      (match !ranges with
      | (s, _) :: _ when !range_dropped && !last_has_origin ->
          let new_col = s + shift_at s in
          if new_col >= 0 then emit new_col []
      | _ -> ());
      range_dropped := false
    in
    List.iter
      (fun segment ->
        if segment <> "" then
          let fields =
            Vlq64.decode_l segment ~pos:0 ~len:(String.length segment)
          in
          match fields with
          | [] -> assert false
          | relative_col :: tail ->
              let col = !col_acc + relative_col in
              col_acc := col;
              let rec leave () =
                match !ranges with
                | (_, e) :: rem when col >= e ->
                    close_range ();
                    ranges := rem;
                    leave ()
                | _ -> ()
              in
              leave ();
              let in_range =
                match !ranges with (s, _) :: _ -> col >= s | [] -> false
              in
              if in_range then range_dropped := true;
              let new_col = col + shift_at col in
              if new_col < 0 || in_range then
                match tail with
                | source :: line :: column :: rest -> (
                    pending_source := !pending_source + source;
                    pending_line := !pending_line + line;
                    pending_col := !pending_col + column;
                    match rest with
                    | name :: _ -> pending_name := !pending_name + name
                    | [] -> ())
                | _ -> ()
              else emit new_col tail)
      segments;
    close_range ();
    String.concat "," (List.rev !output)

(* QCheck Test *)
let test_resize =
  let gen =
    let open QCheck.Gen in
    (* 1. Generate resize_data *)
    int_range (-100) (-1) >>= fun first_delta ->
    list (pair (int_range 1 50) (int_range 0 10)) >>= fun rest ->
    let n = 1 + List.length rest in
    let pos = Array.make n 0 in
    let delta = Array.make n 0 in
    delta.(0) <- first_delta;
    let curr_pos = ref 0 in
    List.iteri
      (fun idx (pos_diff, d) ->
        curr_pos := !curr_pos + pos_diff;
        pos.(idx + 1) <- !curr_pos;
        delta.(idx + 1) <- d)
      rest;
    let rd = { i = n; pos; delta } in

    (* 2. Generate mappings *)
    int_range 0 (200 - first_delta) >>= fun first_rel_col ->
    list (int_range 1 100) >>= fun rest_rel_cols ->
    let rel_cols = first_rel_col :: rest_rel_cols in
    let make_segment rel_col =
      let buf = Buffer.create 16 in
      Vlq64.encode buf rel_col;
      Buffer.add_string buf "ABC";
      Buffer.contents buf
    in
    let segments = List.map make_segment rel_cols in
    let mappings_str = String.concat "," segments in
    return (rd, mappings_str)
  in
  let print (rd, mappings) =
    let rd_str =
      Printf.sprintf "i=%d, pos=[%s], delta=[%s]" rd.i
        (String.concat ";"
           (List.map string_of_int (Array.to_list (Array.sub rd.pos 0 rd.i))))
        (String.concat ";"
           (List.map string_of_int (Array.to_list (Array.sub rd.delta 0 rd.i))))
    in
    Printf.sprintf "resize_data: (%s)\nmappings: %s" rd_str mappings
  in
  QCheck.Test.make ~name:"resize_mappings matches naive implementation"
    ~count:1000 (QCheck.make ~print gen) (fun (rd, mappings) ->
      let res1 = resize_mappings rd mappings in
      let res2 = naive_resize_mappings rd mappings in
      res1 = res2)

(* The same, also dropping the segments in random (sorted, disjoint) ranges of
   input columns, as done for the bodies of removed functions *)
let test_resize_drop =
  let gen =
    let open QCheck.Gen in
    int_range (-100) (-1) >>= fun first_delta ->
    list (pair (int_range 1 50) (int_range 0 10)) >>= fun rest ->
    let n = 1 + List.length rest in
    let pos = Array.make n 0 in
    let delta = Array.make n 0 in
    delta.(0) <- first_delta;
    let curr_pos = ref 0 in
    List.iteri
      (fun idx (pos_diff, d) ->
        curr_pos := !curr_pos + pos_diff;
        pos.(idx + 1) <- !curr_pos;
        delta.(idx + 1) <- d)
      rest;
    let rd = { i = n; pos; delta } in
    list (pair (int_range 0 100) (int_range 1 100)) >>= fun gaps ->
    let drop =
      let start = ref 0 in
      List.map
        (fun (gap, len) ->
          let s = !start + gap in
          start := s + len;
          (s, s + len))
        gaps
    in
    int_range 0 (200 - first_delta) >>= fun first_rel_col ->
    list (int_range 1 100) >>= fun rest_rel_cols ->
    list_size (return (1 + List.length rest_rel_cols)) bool >>= fun named ->
    let make_segment rel_col named =
      let buf = Buffer.create 16 in
      Vlq64.encode buf rel_col;
      Buffer.add_string buf (if named then "ABCD" else "ABC");
      Buffer.contents buf
    in
    let segments =
      List.map2 make_segment (first_rel_col :: rest_rel_cols) named
    in
    return (rd, drop, String.concat "," segments)
  in
  let print (rd, drop, mappings) =
    Printf.sprintf
      "resize_data: (i=%d, pos=[%s], delta=[%s])\ndrop: [%s]\nmappings: %s" rd.i
      (String.concat ";"
         (List.map string_of_int (Array.to_list (Array.sub rd.pos 0 rd.i))))
      (String.concat ";"
         (List.map string_of_int (Array.to_list (Array.sub rd.delta 0 rd.i))))
      (String.concat ";"
         (List.map (fun (s, e) -> Printf.sprintf "%d-%d" s e) drop))
      mappings
  in
  QCheck.Test.make ~name:"resize_mappings ~drop matches naive implementation"
    ~count:1000 (QCheck.make ~print gen) (fun (rd, drop, mappings) ->
      resize_mappings ~drop rd mappings
      = naive_resize_mappings ~drop rd mappings)

(* Idempotence sanity check: resizing with empty resize_data is identity *)
let test_empty =
  QCheck.Test.make ~name:"resize_mappings with empty resize_data is identity"
    ~count:100
    QCheck.(pair (int_range 1 100) (list (int_range 1 100)))
    (fun (first_rel, rest) ->
      let rd = { i = 0; pos = [||]; delta = [||] } in
      let make_segment rel_col =
        let buf = Buffer.create 16 in
        Vlq64.encode buf rel_col;
        Buffer.add_string buf "XYZ";
        Buffer.contents buf
      in
      let mappings =
        String.concat "," (List.map make_segment (first_rel :: rest))
      in
      resize_mappings rd mappings = mappings)

let test_shift =
  let gen =
    let open QCheck.Gen in
    int_range (-100) (-1) >>= fun first_delta ->
    list (pair (int_range 1 50) (int_range 0 10)) >>= fun rest ->
    let n = 1 + List.length rest in
    let pos = Array.make n 0 in
    let delta = Array.make n 0 in
    delta.(0) <- first_delta;
    let curr_pos = ref 0 in
    List.iteri
      (fun idx (pos_diff, d) ->
        curr_pos := !curr_pos + pos_diff;
        pos.(idx + 1) <- !curr_pos;
        delta.(idx + 1) <- d)
      rest;
    let rd = { i = n; pos; delta } in
    list (int_range 0 10) >>= fun diffs ->
    let queries =
      let curr = ref 0 in
      List.map
        (fun diff ->
          curr := !curr + diff;
          !curr)
        diffs
    in
    return (rd, queries)
  in
  let print (rd, queries) =
    let rd_str =
      Printf.sprintf "i=%d, pos=[%s], delta=[%s]" rd.i
        (String.concat ";"
           (List.map string_of_int (Array.to_list (Array.sub rd.pos 0 rd.i))))
        (String.concat ";"
           (List.map string_of_int (Array.to_list (Array.sub rd.delta 0 rd.i))))
    in
    let q_str = String.concat ";" (List.map string_of_int queries) in
    Printf.sprintf "resize_data: (%s)\nqueries: [%s]" rd_str q_str
  in
  let reference_shift_position resize_data x =
    let rec loop idx acc =
      if idx < resize_data.i then
        if x >= resize_data.pos.(idx) then
          loop (idx + 1) (acc + resize_data.delta.(idx))
        else acc
      else acc
    in
    x + loop 0 0
  in
  let test_simultaneous_shift resize_data queries =
    let idx = ref 0 in
    let acc = ref 0 in
    let shift x =
      while !idx < resize_data.i && x >= resize_data.pos.(!idx) do
        acc := !acc + resize_data.delta.(!idx);
        incr idx
      done;
      x + !acc
    in
    List.map shift queries
  in
  QCheck.Test.make ~name:"simultaneous shift matches reference linear shift"
    ~count:1000 (QCheck.make ~print gen) (fun (rd, queries) ->
      let res1 = test_simultaneous_shift rd queries in
      let res2 = List.map (reference_shift_position rd) queries in
      res1 = res2)

(* Semantic oracle: decode a mappings string to the *absolute* position of each
   segment — generated column plus, for a mapped segment, the cumulative
   (source, line, column, name?) — following the source-map delta semantics. A
   bare segment (generated column only) leaves the source/name state untouched;
   a name is present only when a 5th field is. *)
let decode_abs mappings =
  if mappings = "" then []
  else
    let g = ref 0 and s = ref 0 and l = ref 0 and c = ref 0 and nm = ref 0 in
    List.filter_map
      (fun seg ->
        if seg = "" then None
        else
          match Vlq64.decode_l seg ~pos:0 ~len:(String.length seg) with
          | [] -> None
          | dcol :: tail ->
              g := !g + dcol;
              let src =
                match tail with
                | ds :: dl :: dc :: rest ->
                    s := !s + ds;
                    l := !l + dl;
                    c := !c + dc;
                    let name =
                      match rest with
                      | dn :: _ ->
                          nm := !nm + dn;
                          Some !nm
                      | [] -> None
                    in
                    Some (!s, !l, !c, name)
                | _ -> None
              in
              Some (!g, src))
      (String.split_on_char ',' mappings)

let ref_shift resize_data x =
  let s = ref 0 in
  for k = 0 to resize_data.i - 1 do
    if resize_data.pos.(k) <= x then s := !s + resize_data.delta.(k)
  done;
  x + !s

(* The absolute positions the output *should* have: each input segment shifted,
   dropped iff its shifted generated column is negative, with its absolute
   source position otherwise preserved unchanged. Independent of how
   [resize_mappings] re-encodes deltas, so it pins down the behaviour a
   drop-and-forget implementation gets wrong. *)
let expected_abs resize_data mappings =
  List.filter_map
    (fun (g, src) ->
      let g' = ref_shift resize_data g in
      if g' < 0 then None else Some (g', src))
    (decode_abs mappings)

let test_resize_semantic =
  let gen =
    let open QCheck.Gen in
    int_range (-100) (-1) >>= fun first_delta ->
    list_size (int_range 0 8) (pair (int_range 1 40) (int_range 0 8))
    >>= fun rest ->
    let n = 1 + List.length rest in
    let pos = Array.make n 0 in
    let delta = Array.make n 0 in
    delta.(0) <- first_delta;
    let curr = ref 0 in
    List.iteri
      (fun i (dp, d) ->
        curr := !curr + dp;
        pos.(i + 1) <- !curr;
        delta.(i + 1) <- d)
      rest;
    let rd = { i = n; pos; delta } in
    (* Segments with monotonically non-decreasing generated columns (a source
       map invariant) and a mix of bare / mapped / named tails, tails allowed
       negative deltas. Early segments land in the drop zone; later ones
       survive and must fold in the dropped tails. *)
    list_size (int_range 0 60)
      ( int_range 0 12 >>= fun dcol ->
        int_range 0 2 >>= fun kind ->
        int_range (-5) 5 >>= fun s ->
        int_range (-5) 5 >>= fun l ->
        int_range (-5) 5 >>= fun c ->
        int_range (-5) 5 >>= fun nm ->
        return
          (match kind with
          | 0 -> [ dcol ]
          | 1 -> [ dcol; s; l; c ]
          | _ -> [ dcol; s; l; c; nm ]) )
    >>= fun seg_fields ->
    let mappings =
      String.concat ","
        (List.map
           (fun fl ->
             let b = Buffer.create 8 in
             Vlq64.encode_l b fl;
             Buffer.contents b)
           seg_fields)
    in
    return (rd, mappings)
  in
  let print (rd, mappings) =
    Printf.sprintf "i=%d, pos=[%s], delta=[%s]\nmappings: %s" rd.i
      (String.concat ";"
         (List.map string_of_int (Array.to_list (Array.sub rd.pos 0 rd.i))))
      (String.concat ";"
         (List.map string_of_int (Array.to_list (Array.sub rd.delta 0 rd.i))))
      mappings
  in
  QCheck.Test.make
    ~name:"resize_mappings preserves absolute source positions of survivors"
    ~count:2000 (QCheck.make ~print gen) (fun (rd, mappings) ->
      decode_abs (resize_mappings rd mappings) = expected_abs rd mappings)

(* [iter_sources] numbers a section, and a source within it, only when there is
   more than one to name. An embedder derives each source's on-disk filename
   from that pair and reads it back with the same derivation, so the convention
   is part of the contract rather than an implementation detail. *)
let test_iter_sources () =
  let map sources =
    Standard.of_string
      (Printf.sprintf {|{"version":3,"sources":[%s],"names":[],"mappings":"A"}|}
         (String.concat "," (List.map (Printf.sprintf "%S") sources)))
  in
  let collect sections =
    let acc = ref [] in
    iter_sources
      (concatenate (List.mapi (fun i s -> (i * 100, map s)) sections))
      (fun i j source -> acc := (i, j, source) :: !acc);
    List.rev !acc
  in
  let check name expected got =
    if got <> expected then (
      let show (i, j, s) =
        let idx = function None -> "-" | Some i -> string_of_int i in
        Printf.sprintf "(%s,%s,%s)" (idx i) (idx j) s
      in
      let show_all l = String.concat " " (List.map show l) in
      Printf.eprintf "iter_sources, %s:\n  expected %s\n  got      %s\n" name
        (show_all expected) (show_all got);
      exit 1)
  in
  check "one section, one source"
    [ (None, None, "a.ml") ]
    (collect [ [ "a.ml" ] ]);
  check "one section, two sources"
    [ (None, Some 0, "a.ml"); (None, Some 1, "b.ml") ]
    (collect [ [ "a.ml"; "b.ml" ] ]);
  check "two sections, one source each"
    [ (Some 0, None, "a.ml"); (Some 1, None, "b.ml") ]
    (collect [ [ "a.ml" ]; [ "b.ml" ] ]);
  check "two sections, only the multi-source one numbers its sources"
    [
      (Some 0, Some 0, "a.ml"); (Some 0, Some 1, "b.ml"); (Some 1, None, "c.ml");
    ]
    (collect [ [ "a.ml"; "b.ml" ]; [ "c.ml" ] ])

let () =
  test_iter_sources ();
  let suite =
    [
      test_resize;
      test_resize_drop;
      test_resize_semantic;
      test_empty;
      test_shift;
    ]
  in
  let result = QCheck_runner.run_tests suite in
  if result <> 0 then exit result
