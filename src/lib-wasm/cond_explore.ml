module Diagnostic = Wax_utils.Diagnostic

let report diagnostics ?truncation_location ~explain ~truncated configurations =
  (* error key -> (captured diagnostic, accumulated reachability) *)
  let errors : (string, Diagnostic.entry * Cond_solver.t) Hashtbl.t =
    Hashtbl.create 16
  in
  (* The union of every reachable configuration's assumption: the whole feasible
     space. A [universal] diagnostic (e.g. an unused local) is only reported if
     it arises across all of it — being unused in some branches but used in
     others is not "unused". *)
  let feasible = ref Cond_solver.false_ in
  List.iter
    (fun (entries, a_full) ->
      (* Backstop: a configuration's assumption is normally satisfiable (the
         explorations prune unreachable branches up front). This guards against
         any residual incompleteness by discarding errors should an infeasible
         configuration slip through. *)
      if Cond_solver.is_satisfiable a_full then begin
        feasible := Cond_solver.or_ !feasible a_full;
        List.iter
          (fun e ->
            let loc = Diagnostic.entry_location e in
            let key =
              Printf.sprintf "%d:%d:%s" loc.loc_start.pos_cnum
                loc.loc_end.pos_cnum
                (Wax_utils.Message.to_plain_string (Diagnostic.entry_message e))
            in
            let reach =
              match Hashtbl.find_opt errors key with
              | Some (_, r) -> Cond_solver.or_ r a_full
              | None -> a_full
            in
            Hashtbl.replace errors key (e, reach))
          entries
      end)
    configurations;
  let entries = Hashtbl.fold (fun _ v acc -> v :: acc) errors [] in
  (* Drop a [universal] diagnostic unless it arose in every reachable
     configuration, i.e. its accumulated reachability covers the whole feasible
     space. *)
  let entries =
    List.filter
      (fun (e, reach) ->
        (not (Diagnostic.entry_universal e))
        || Cond_solver.logical_implies !feasible reach)
      entries
  in
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
        (* A [universal] diagnostic holds across the whole feasible space, so it
           carries no "reachable when" qualifier. *)
        match if Diagnostic.entry_universal e then None else explain reach with
        | None -> base_hint
        | Some s ->
            let reach =
              Wax_utils.Message.text (Printf.sprintf "reachable when %s" s)
            in
            Some
              (match base_hint with
              | Some h -> Wax_utils.Message.(h ++ reach)
              | None -> reach)
      in
      Diagnostic.report diagnostics
        ~location:(Diagnostic.entry_location e)
        ~severity:(Diagnostic.entry_severity e)
        ?warning:(Diagnostic.entry_warning e)
        ?hint
        ~related:(Diagnostic.entry_related e)
        ~message:(Diagnostic.entry_message e)
        ())
    entries;
  if truncated then
    match truncation_location with
    | Some location ->
        Diagnostic.report diagnostics ~location ~severity:Warning
          ~warning:Wax_utils.Warning.Truncated_coverage
          ~message:
            Wax_utils.Message.(
              text "Too many conditional configurations (over"
              ++ int Cond_plan.max_runs
              ^^ text "); coverage was truncated.")
          ()
    | None -> ()
