type flag = Never | Always | Auto

let should_use_color ~color ~out_channel =
  match color with
  | Never -> false
  | Always -> true
  | Auto -> (
      match out_channel with
      | None -> false
      | Some oc -> (
          Option.is_none (Sys.getenv_opt "NO_COLOR")
          && (match Sys.getenv_opt "TERM" with
            | None | Some "dumb" -> false
            | _ -> true)
          &&
            try Unix.isatty (Unix.descr_of_out_channel oc)
            with Unix.Unix_error _ -> false))

let update_flag ~color =
  if should_use_color ~color ~out_channel:(Some stdout) then Always else Never

module Ansi = struct
  let reset = "\027[0m"
  let bold = "\027[1m"
  let red = "\027[31m"
  let high_red = "\027[91m"
  let green = "\027[32m"
  let yellow = "\027[33m"
  let high_yellow = "\027[93m"
  let blue = "\027[34m"
  let magenta = "\027[35m"
  let cyan = "\027[36m"
  let white = "\027[37m"
  let grey = "\027[90m"
end

type style =
  | Keyword (* func / fn *)
  | Instruction (* i32.const *)
  | Attribute (* offset=4 *)
  | Type (* i32 *)
  | Identifier
  | Constant
  | String
  | Operator (* + *)
  | Annotation (* (@...), rust macro *)
  | Comment
  | Punctuation (* { ( : *)

type theme = {
  keyword : string;
  instruction : string;
  attribute : string;
  type_ : string;
  identifier : string;
  constant : string;
  string : string;
  operator : string;
  annotation : string;
  comment : string;
  punctuation : string;
  reset : string;
}

let escape_sequence theme style =
  match style with
  | Keyword -> theme.keyword
  | Instruction -> theme.instruction
  | Attribute -> theme.attribute
  | Type -> theme.type_
  | Identifier -> theme.identifier
  | Constant -> theme.constant
  | String -> theme.string
  | Operator -> theme.operator
  | Annotation -> theme.annotation
  | Comment -> theme.comment
  | Punctuation -> theme.punctuation

(* The two source palettes, one per surface language. Each is the single source
   of truth: the language's source printer ([Wax_lang.Output] / [Wax_wasm.Output])
   uses it to render whole modules, and diagnostics use it to colour an AST
   fragment (a type, an identifier) embedded in a message, so a diagnostic about
   Wax code and one about WebAssembly code colour their types the same way that
   language's source does (e.g. Wax types cyan, WAT types red). *)
let wax_theme =
  {
    keyword = Ansi.bold ^ Ansi.magenta;
    operator = Ansi.bold ^ Ansi.white;
    annotation = Ansi.blue;
    attribute = Ansi.magenta;
    type_ = Ansi.cyan;
    identifier = Ansi.yellow;
    constant = Ansi.bold ^ Ansi.blue;
    string = Ansi.green;
    comment = Ansi.grey;
    punctuation = Ansi.white;
    instruction = "";
    reset = Ansi.reset;
  }

let wat_theme =
  {
    keyword = Ansi.bold ^ Ansi.magenta;
    instruction = Ansi.white;
    attribute = Ansi.magenta;
    type_ = Ansi.red;
    identifier = Ansi.yellow;
    constant = Ansi.bold ^ Ansi.blue;
    string = Ansi.green;
    annotation = Ansi.blue;
    comment = Ansi.grey;
    punctuation = Ansi.cyan;
    operator = "";
    reset = Ansi.reset;
  }

let no_color =
  {
    keyword = "";
    instruction = "";
    attribute = "";
    type_ = "";
    identifier = "";
    constant = "";
    string = "";
    annotation = "";
    comment = "";
    punctuation = "";
    operator = "";
    reset = "";
  }
