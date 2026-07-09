open Ast

(* [Func] carries an inline record, so each field is rebound and the record
   reconstructed explicitly (an inline record cannot be captured with [as]). *)
let rec map_fields fields =
  List.map
    (fun field ->
      match field.desc with
      | Text.Func { id = None; typ; locals; instrs; exports }
        when match exports with
             | export :: _ -> Lexer.is_valid_identifier export.desc
             | [] -> false ->
          let export = List.hd exports in
          {
            field with
            desc = Text.Func { id = Some export; typ; locals; instrs; exports };
          }
      | Text.Module_if_annotation { cond; then_fields; else_fields } ->
          {
            field with
            desc =
              Text.Module_if_annotation
                {
                  cond;
                  then_fields =
                    { then_fields with desc = map_fields then_fields.desc };
                  else_fields =
                    Option.map
                      (fun e -> { e with desc = map_fields e.desc })
                      else_fields;
                };
          }
      | _ -> field)
    fields

let name_functions_from_exports (name, fields) = (name, map_fields fields)
