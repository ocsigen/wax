open Wax_linker.Js_source_map
module Vlq64 = Wax_linker.Vlq64

(* Naive reference implementation *)
let naive_resize_mappings resize_data mappings =
  if mappings = "" || resize_data.i = 0 then mappings
  else
    let segments = String.split_on_char ',' mappings in
    let col_acc = ref 0 in
    let new_col_acc = ref 0 in
    let new_segments =
      List.map
        (fun segment ->
          if segment = "" then ""
          else
            let fields =
              Vlq64.decode_l segment ~pos:0 ~len:(String.length segment)
            in
            match fields with
            | [] -> assert false
            | relative_col :: _ ->
                let col = !col_acc + relative_col in
                col_acc := col;
                let shift = ref 0 in
                for k = 0 to resize_data.i - 1 do
                  if resize_data.pos.(k) <= col then
                    shift := !shift + resize_data.delta.(k)
                done;
                let new_col = col + !shift in
                let new_relative_col = new_col - !new_col_acc in
                new_col_acc := new_col;
                let buf = Buffer.create 16 in
                Vlq64.encode buf new_relative_col;
                let input =
                  {
                    Vlq64.string = segment;
                    pos = 0;
                    len = String.length segment;
                  }
                in
                let _ = Vlq64.decode input in
                let rest_str =
                  String.sub segment input.pos
                    (String.length segment - input.pos)
                in
                Buffer.add_string buf rest_str;
                Buffer.contents buf)
        segments
    in
    String.concat "," new_segments

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
    int_range (1 - first_delta) (200 - first_delta) >>= fun first_rel_col ->
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

let () =
  let suite = [ test_resize; test_empty; test_shift ] in
  let result = QCheck_runner.run_tests suite in
  if result <> 0 then exit result
