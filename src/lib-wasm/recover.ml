(* Token classification for the WAT parser's panic-mode error recovery
   ({!Parsing.Make.parse_recover}). WAT is fully parenthesized, so unlike Wax
   there are no [Boundary]/[Leader] anchors: every construct is [( … )], and the
   only resynchronization points are the parentheses. Recovery therefore leans on
   the nesting-aware skip and on [close_pending] auto-closing with [")"]: an
   error inside a construct is repaired by inserting the [")"]s needed to close
   the pending constructs, so what parsed so far reduces into the best-effort AST
   rather than being unwound away when the enclosing [")"] is reached.

   Every opener — the bare [LPAREN] and the compound [(param]/[(result]/… tokens
   the lexer folds — is [Open]; [RPAREN] is [Close]; end-of-input is [Terminal];
   everything else (keywords, mnemonics, literals) is [Skip]. *)
let sync : Tokens.token -> Parsing.sync_class = function
  | Tokens.LPAREN | Tokens.LPAREN_DESCRIPTOR | Tokens.LPAREN_DESCRIBES
  | Tokens.LPAREN_CATCH | Tokens.LPAREN_CATCH_ALL | Tokens.LPAREN_CATCH_ALL_REF
  | Tokens.LPAREN_CATCH_REF | Tokens.LPAREN_ON | Tokens.LPAREN_EXPORT
  | Tokens.LPAREN_IMPORT | Tokens.LPAREN_LOCAL | Tokens.LPAREN_PARAM
  | Tokens.LPAREN_RESULT | Tokens.LPAREN_THEN | Tokens.LPAREN_TYPE ->
      Open
  | Tokens.RPAREN -> Close
  | Tokens.EOF -> Terminal
  | _ -> Skip

(* The closing bracket recovery may insert to auto-close a construct still open
   in front of a boundary (or at end of input); passed as [?closers]. *)
let closers = [ Tokens.RPAREN ]

(* WAT has no statement separator, but a missing {e operand} is the common
   mid-typing slip — [(i32.const)] wants a number before its [)]. Offering a
   zero-width [0] repairs the group in place: the const family (and integer
   indices such as [(br)]) all accept a [NAT], so the instruction stays in the
   best-effort AST with a "Missing integer" diagnostic instead of the whole
   group being dropped. Passed as [?insert]. *)
let insert = [ (Tokens.NAT "0", Wax_utils.Message.text "Missing integer.") ]

(* A missing closer — [(module (func … (func …] with a [)] left out — surfaces
   as a field-opening keyword offered where an instruction was expected. This
   [barrier] (the [(] to re-offer, and the predicate recognizing those keywords)
   lets [Parsing.parse_recover] close the enclosing field and restart at the new
   one instead of letting paren-depth counting swallow it. Only the bare field
   keywords (not the compound [(type]/[(import]/… openers, which also occur
   nested) are treated as barriers. Passed as [?barrier]. *)
let barrier =
  ( Tokens.LPAREN,
    function
    | Tokens.FUNC | Tokens.GLOBAL | Tokens.MEMORY | Tokens.TABLE | Tokens.ELEM
    | Tokens.DATA | Tokens.TAG | Tokens.START | Tokens.REC | Tokens.MODULE ->
        true
    | _ -> false )
