(* Token classification for the WAT parser's panic-mode error recovery
   ({!Wax_utils.Parsing.Make.parse_recover}). WAT is fully parenthesized, so unlike Wax
   there are no [Boundary]/[Leader] anchors: every construct is [( … )], and the
   only resynchronization points are the parentheses. Recovery therefore leans on
   the nesting-aware skip and on [close_pending] auto-closing with [")"]: an
   error inside a construct is repaired by inserting the [")"]s needed to close
   the pending constructs, so what parsed so far reduces into the best-effort AST
   rather than being unwound away when the enclosing [")"] is reached.

   Every opener — the bare [LPAREN] and the compound [(param]/[(result]/… tokens
   the lexer folds — is [Open]; [RPAREN] is [Close]; end-of-input is [Terminal];
   everything else (keywords, mnemonics, literals) is [Skip]. *)
let sync : Tokens.token -> Wax_utils.Parsing.sync_class = function
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
   in front of a boundary (or at end of input); passed as [?closers]. Each is
   paired with its source spelling, so a validated auto-close can offer the
   concatenation of the closers it inserted as a machine-applicable quick fix. *)
let closers = [ (Tokens.RPAREN, ")") ]

(* WAT has no statement separator, but a missing {e operand} is the common
   mid-typing slip — [(call)] wants an index, [(i32.const)] a number. Offering a
   zero-width placeholder repairs the group in place, keeping the instruction in
   the best-effort AST (with a "Missing …" diagnostic) instead of dropping the
   whole group. Two candidates, tried in order, so the diagnostic names what is
   actually missing: a named index [$_] first — accepted exactly where an index
   is expected (a func / label / type / … use), which a bare number would also
   fit but describe less accurately — then a [0], accepted at the numeric-literal
   positions an index is not (the const family, lane / align operands, where a
   float may equally be wanted, hence "number" not "integer"). The parser picks
   the first candidate its erroring state can shift, so index positions report
   "Missing index" and the rest "Missing number". Passed as [?insert]. *)
let insert =
  [
    ( Tokens.ID (Wax_utils.Ast.no_loc "_"),
      Wax_utils.Message.text "Missing index.",
      false,
      "$_" );
    (Tokens.NAT "0", Wax_utils.Message.text "Missing number.", false, "0");
  ]

(* A missing closer — [(module (func … (func …] with a [)] left out — surfaces
   as a field-opening keyword offered where an instruction was expected. This
   [barrier] lets [Wax_utils.Parsing.parse_recover] close the enclosing field and restart
   at the new one instead of letting paren-depth counting swallow it. It has
   three parts: the bare [(] to re-offer; the predicate recognizing a field
   keyword written after a bare [(] (offered as the pair [( ; keyword]); and the
   predicate recognizing a {e fused} field opener the lexer folds into one token
   ([(type]/[(import]/[(export]), offered alone. The bare field keywords have no
   fused form; the fused openers are also valid nested (a [(type …)] typeuse, an
   inline [(import …)]/[(export …)]), so both predicates fire only at the
   enclosing recovery level, never on skipped nested content. Passed as
   [?barrier]. *)
let barrier =
  ( Tokens.LPAREN,
    (function
    | Tokens.FUNC | Tokens.GLOBAL | Tokens.MEMORY | Tokens.TABLE | Tokens.ELEM
    | Tokens.DATA | Tokens.TAG | Tokens.START | Tokens.REC | Tokens.MODULE ->
        true
    | _ -> false),
    function
    | Tokens.LPAREN_TYPE | Tokens.LPAREN_IMPORT | Tokens.LPAREN_EXPORT -> true
    | _ -> false )
