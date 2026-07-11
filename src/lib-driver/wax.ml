type binary_module = Wax_conversion.Driver.binary_module

module Define = struct
  type value = Wax_wasm.Cond_specialize.value =
    | Bool of bool
    | Version of int * int * int
    | String of string

  type t = Wax_wasm.Cond_specialize.bindings

  let of_list = Wax_wasm.Cond_specialize.of_list
end

let wat_to_binary ?defines ?name_functions ?validate ~filename text =
  Wax_conversion.Driver.wat_to_binary ?defines ?name_functions ?validate
    ~filename text

let wax_to_binary ?defines ?validate ~filename text =
  Wax_conversion.Driver.wax_to_binary ?defines ?validate ~filename text

let output_binary = Wax_conversion.Driver.output_binary

module Link = struct
  type input = {
    module_name : string;
    file : string;
    code : string option;
    source_map : string option;
  }

  let f ?filter_export inputs ~output_file =
    let any_source_map = List.exists (fun i -> i.source_map <> None) inputs in
    let inputs =
      List.map
        (fun { module_name; file; code; source_map } ->
          {
            Wax_linker.Wasm_link.module_name;
            file;
            code;
            opt_source_map =
              Option.map Wax_linker.Source_map.Standard.of_string source_map;
          })
        inputs
    in
    let sm = Wax_linker.Wasm_link.f ?filter_export inputs ~output_file in
    if any_source_map then Some (Wax_linker.Source_map.to_string sm) else None
end
