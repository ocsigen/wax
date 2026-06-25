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
