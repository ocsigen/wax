(* Token classification for the Wax parser's panic-mode error recovery, shared
   by the CLI ([Wax_conversion.Driver.wax_parse_recover], behind
   [wax check --all-errors]) and the editor ([src/editor/wax_format_js.ml]). It
   lives here, free of the [Fast_parser] tables, so the editor's size-sensitive
   wasm build can use it without linking the fast parser (see the module note in
   wax_format_js.ml).

   End-of-input stops recovery and everything not listed here is skipped while
   scanning for one of these boundaries. Two kinds, both handled by the same
   "unwind the stack to a state that can shift this token, then shift it" step
   (see {!Wax_wasm.Parsing.Make.parse_recover}):

   - Trailing closers ([";"], ["}"], [")"], ["]"]) — resync as the tail of the
     broken construct; the paren/bracket closers give finer, expression-internal
     recovery than the statement/block ones.
   - Leading keywords that begin a new top-level item or statement. They let
     recovery resync at the next construct even when the error consumed the
     trailing closer. Only keywords that can never continue an expression are
     included: the expression forms [if]/[loop]/[block]/[match]/[do]/[while] are
     left out, since in this expression-oriented grammar they can occur
     mid-expression and stopping at one would resync too early. *)
let sync : Tokens.token -> Wax_wasm.Parsing.sync_class = function
  | Tokens.SEMI | Tokens.RBRACE | Tokens.RPAREN | Tokens.RBRACKET -> Boundary
  | Tokens.FN | Tokens.TYPE | Tokens.REC | Tokens.IMPORT | Tokens.MEMORY
  | Tokens.DATA | Tokens.TABLE | Tokens.ELEM | Tokens.TAG | Tokens.CONST
  | Tokens.LET | Tokens.RETURN | Tokens.BR | Tokens.BR_IF | Tokens.BR_TABLE
  | Tokens.THROW | Tokens.THROW_REF | Tokens.BECOME | Tokens.NOP
  | Tokens.UNREACHABLE ->
      Boundary
  | Tokens.EOF -> Terminal
  | _ -> Skip
