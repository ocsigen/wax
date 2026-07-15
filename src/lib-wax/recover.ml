(* Token classification for the Wax parser's panic-mode error recovery, shared
   by the CLI ([Wax_conversion.Driver.wax_parse_recover], behind
   [wax check --all-errors]) and the editor ([src/editor/wax_format_js.ml]). It
   lives here, free of the [Fast_parser] tables, so the editor's size-sensitive
   wasm build can use it without linking the fast parser (see the module note in
   wax_format_js.ml).

   End-of-input stops recovery and everything not listed here is skipped while
   scanning for one of these boundaries. The kinds (all handled by the same
   "unwind the stack to a state that can shift this token, then shift it" step,
   see {!Wax_wasm.Parsing.Make.parse_recover}):

   - Openers ([Open]: ["{"], ["("], ["["]) and closers ([Close]: ["}"], [")"],
     ["]"]). The skip is nesting-aware: an opener met while skipping descends a
     level and the matching closer ascends it again, so only a closer at the
     {e outer} level resyncs — a closer or [";"] belonging to a group opened
     inside the skipped span no longer resyncs the enclosing construct. The
     paren/bracket closers give finer, expression-internal recovery than the
     statement/block ones.
   - The statement separator [";"] ([Boundary]) — a resync point, but only at
     the outer nesting level (like a closer).
   - Leading keywords that begin a new top-level item or statement ([Leader]).
     They let recovery resync at the next construct even when the error consumed
     the trailing closer, so they resync at {e any} depth (an unbalanced opener
     must not swallow the next item). Only keywords that can never continue an
     expression are included: the expression forms [if]/[loop]/[block]/[match]/
     [do]/[while] are left out, since in this expression-oriented grammar they
     can occur mid-expression and stopping at one would resync too early. *)
let sync : Tokens.token -> Wax_wasm.Parsing.sync_class = function
  | Tokens.LBRACE | Tokens.LPAREN | Tokens.LBRACKET -> Open
  | Tokens.RBRACE | Tokens.RPAREN | Tokens.RBRACKET -> Close
  | Tokens.SEMI -> Boundary
  | Tokens.FN | Tokens.TYPE | Tokens.REC | Tokens.IMPORT | Tokens.MEMORY
  | Tokens.DATA | Tokens.TABLE | Tokens.ELEM | Tokens.TAG | Tokens.CONST
  | Tokens.LET | Tokens.RETURN | Tokens.BR | Tokens.BR_IF | Tokens.BR_TABLE
  | Tokens.THROW | Tokens.THROW_REF | Tokens.BECOME | Tokens.NOP
  | Tokens.UNREACHABLE ->
      Leader
  | Tokens.EOF -> Terminal
  | _ -> Skip

(* The token recovery may insert in front of an offending token: a statement
   separator [";"]. A dropped [;] between two statements is by far the most
   common Wax syntax slip, and the parser state that follows a complete statement
   can shift [SEMI], so [Parsing.parse_recover] inserts one there (reporting a
   "Missing ';'") rather than skipping to the next boundary. *)
let insert = (Tokens.SEMI, ";")

(* The closing brackets recovery may insert to auto-close a construct left open
   at end of input, so the function/block the user is still typing reduces into
   the best-effort AST (for the editor outline) instead of being unwound away.
   See the [closers] argument of [Parsing.parse_recover]. *)
let closers = [ Tokens.RBRACE; Tokens.RPAREN; Tokens.RBRACKET ]
