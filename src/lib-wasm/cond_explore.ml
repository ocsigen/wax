module Diagnostic = Utils.Diagnostic

module Bdd_tbl = Hashtbl.Make (struct
  type t = Cond_solver.t

  let equal = Cond_solver.equal
  let hash = Cond_solver.hash
end)

let max_configurations = 4096

let check_all diagnostics ?truncation_location
    ?(explain = fun env c -> Cond_solver.explain env c) ~specialize ~check () =
  (* A fresh solver state per call, so interning/diagnostics never leak between
     modules processed in the same process. *)
  let env = Cond_solver.create () in
  let queue = Queue.create () in
  Queue.push Cond_solver.true_ queue;
  let processed = Bdd_tbl.create 16 in
  (* error key -> (captured diagnostic, accumulated reachability) *)
  let errors : (string, Diagnostic.entry * Cond_solver.t) Hashtbl.t =
    Hashtbl.create 16
  in
  let count = ref 0 in
  let truncated = ref false in
  while (not (Queue.is_empty queue)) && not !truncated do
    let asm = Queue.pop queue in
    if Bdd_tbl.mem processed asm || not (Cond_solver.is_satisfiable asm) then ()
    else if !count >= max_configurations then truncated := true
    else begin
      Bdd_tbl.add processed asm ();
      incr count;
      let a_full = ref Cond_solver.true_ in
      let record lit = a_full := Cond_solver.and_ !a_full lit in
      let enqueue b = Queue.push b queue in
      let cfg = specialize env asm ~enqueue ~record in
      let cctx = Diagnostic.collector () in
      check cctx cfg;
      (* Backstop: [specialize] prunes unreachable branches up front, so a
         configuration's full assumption is normally satisfiable. This guards
         against any residual incompleteness by discarding errors should an
         infeasible configuration slip through. *)
      if Cond_solver.is_satisfiable !a_full then
        List.iter
          (fun e ->
            let loc = Diagnostic.entry_location e in
            let key =
              Printf.sprintf "%d:%d:%s" loc.loc_start.pos_cnum
                loc.loc_end.pos_cnum
                (Format.asprintf "%a"
                   (fun f () -> Diagnostic.entry_message e f ())
                   ())
            in
            let reach =
              match Hashtbl.find_opt errors key with
              | Some (_, r) -> Cond_solver.or_ r !a_full
              | None -> !a_full
            in
            Hashtbl.replace errors key (e, reach))
          (Diagnostic.collected cctx)
    end
  done;
  let entries = Hashtbl.fold (fun _ v acc -> v :: acc) errors [] in
  let entries =
    List.sort
      (fun (e1, _) (e2, _) ->
        let l1 = Diagnostic.entry_location e1
        and l2 = Diagnostic.entry_location e2 in
        compare
          (l1.loc_start.pos_cnum, l1.loc_end.pos_cnum)
          (l2.loc_start.pos_cnum, l2.loc_end.pos_cnum))
      entries
  in
  List.iter
    (fun (e, reach) ->
      let base_hint = Diagnostic.entry_hint e in
      let hint =
        match explain env reach with
        | None -> base_hint
        | Some s ->
            Some
              (fun f () ->
                (match base_hint with
                | Some h ->
                    h f ();
                    Format.pp_print_space f ()
                | None -> ());
                Format.fprintf f "reachable when %s" s)
      in
      Diagnostic.report diagnostics
        ~location:(Diagnostic.entry_location e)
        ~severity:(Diagnostic.entry_severity e)
        ?hint
        ~related:(Diagnostic.entry_related e)
        ~message:(Diagnostic.entry_message e)
        ())
    entries;
  if !truncated then
    match truncation_location with
    | Some location ->
        Diagnostic.report diagnostics ~location ~severity:Warning
          ~message:(fun fmt () ->
            Format.fprintf fmt
              "Too many conditional configurations (over %d); coverage was \
               truncated."
              max_configurations)
          ()
    | None -> ()
