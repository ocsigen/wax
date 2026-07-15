/**
 * @file Tree-sitter grammar for the Wax language (a Rust-like syntax for WebAssembly).
 * @license MIT
 *
 * Re-encodes the surface syntax of `src/lib-wax/parser.mly` and `src/lib-wax/lexer.ml`.
 * It parses structure only: no type-checking, and no post-parse `#[if]`/`#[else]`
 * pairing (those are kept as sibling nodes). See tree-sitter-wax/README.md.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Higher binds tighter (tree-sitter convention). Mirrors parser.mly:105-119.
const PREC = {
  block: 1, // prec_ident / prec_block   (lowest tiebreak)
  branch: 2, // prec_branch  (right)   -- br_if/br_on_* payloads
  assign: 3, // = :=         (right)
  ternary: 4, // ? :          (right)
  compare: 5, // == != < <s ... (nonassoc)
  or: 6, // |
  xor: 7, // ^
  and: 8, // &
  shift: 9, // << >>s >>u
  add: 10, // + -
  mul: 11, // * / /s /u %s %u
  cast: 12, // as is
  unary: 13, // prefix ! + -
  postfix: 15, // . ( [   and postfix `!` (NonNull)
};

// Word-keywords (lexer.ml:231-282). Reserved via `word: $ => $.identifier`.
// Also accepted as label names (parser.mly:405-459), so listed for `label`.
const KEYWORDS = [
  'null', 'inf', 'nan', 'tag', 'fn', 'mut', 'type', 'rec', 'open', 'nop',
  'unreachable', 'do', 'while', 'loop', 'if', 'else', 'let', 'const', 'as',
  'is', 'become', 'br', 'br_if', 'br_table', 'dispatch', 'match', 'br_on_null',
  'br_on_non_null', 'br_on_cast', 'br_on_cast_fail', 'return', 'try', 'catch',
  'throw', 'throw_ref', 'cont', 'cont_new', 'cont_bind', 'suspend', 'resume',
  'resume_throw', 'resume_throw_ref', 'switch', 'memory', 'import', 'pagesize',
  'shared', 'descriptor', 'describes', 'data', 'table', 'elem',
];

module.exports = grammar({
  name: 'wax',

  word: $ => $.identifier,

  externals: $ => [$.block_comment],

  extras: $ => [/[ \t\r\n]/, $.line_comment, $.block_comment],

  supertypes: $ => [
    $._expression,
    $._statement,
    $._block_instruction,
    $._value_type,
  ],

  conflicts: $ => [
    // A block-instruction as a terminal block item vs the start of an
    // expression-statement that continues with a postfix/binary operator.
    [$._expression, $._block_item],
  ],

  rules: {
    source_file: $ => repeat($._module_item),

    _module_item: $ => choice(
      $._module_field,
      ';',
    ),

    // ---------------------------------------------------------------------
    // Lexical layer
    // ---------------------------------------------------------------------

    // (XID_Start | _) XID_Continue*  with apostrophe allowed in continue
    // position (lexer.ml:3-12). A lone `_` is UNDERSCORE, handled elsewhere.
    identifier: $ =>
      /[\p{XID_Start}][\p{XID_Continue}']*|_[\p{XID_Continue}']+/u,

    // Decimal or 0x-hex, with `_` digit separators (lexer.ml:38-43). No sign.
    integer_literal: $ => token(choice(
      /[0-9](_?[0-9])*/,
      /0[xX][0-9a-fA-F](_?[0-9a-fA-F])*/,
    )),

    // decfloat | hexfloat | nan:0x… (lexer.ml:45-54).
    float_literal: $ => {
      const dec = /[0-9](_?[0-9])*/;
      const hex = /[0-9a-fA-F](_?[0-9a-fA-F])*/;
      const decExp = /[eE][+-]?[0-9](_?[0-9])*/;
      const hexExp = /[pP][+-]?[0-9](_?[0-9])*/;
      return token(choice(
        // num ('.' num?)? exp   |   num '.' num?
        seq(dec, choice(
          seq(optional(seq('.', optional(dec))), decExp),
          seq('.', optional(dec)),
        )),
        // 0x hexnum ('.' hexnum?)? pexp   |   0x hexnum '.' hexnum?
        seq(/0[xX]/, hex, choice(
          seq(optional(seq('.', optional(hex))), hexExp),
          seq('.', optional(hex)),
        )),
        seq(/nan:0[xX]/, hex),
      ));
    },

    string_literal: $ => seq(
      '"',
      repeat(choice(
        token.immediate(prec(1, /[^"\\\x00-\x1f\x7f]+/)),
        $.escape_sequence,
      )),
      '"',
    ),

    // A single atomic token (like the sedlex lexer), so `'a'` competes as one
    // 3-char token against the 1-char label quote and wins by longest match —
    // while `'foo` (no closing quote) fails here and falls through to a label.
    char_literal: $ => token(seq(
      "'",
      choice(
        /[^'\\\x00-\x1f\x7f]/,
        /\\[tnr'"\\]/,
        /\\x[0-9a-fA-F][0-9a-fA-F]/,
        /\\u\{[0-9a-fA-F](_?[0-9a-fA-F])*\}/,
      ),
      "'",
    )),

    escape_sequence: $ => token.immediate(choice(
      /\\[tnr'"\\]/,
      /\\x[0-9a-fA-F][0-9a-fA-F]/,
      /\\u\{[0-9a-fA-F](_?[0-9a-fA-F])*\}/,
    )),

    line_comment: $ => token(seq('//', /[^\r\n]*/)),

    // A `'` followed by an identifier or keyword (parser.mly:460-464). Kept at
    // the grammar level (not a single token) so `'a'` still lexes as a char.
    label: $ => seq("'", field('name', $._label_name)),

    _label_name: $ => choice($.identifier, ...KEYWORDS),

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    _value_type: $ => choice(
      $.reference_type,
      $.primitive_type,
    ),

    // i32/i64/f32/f64/v128 (value), i8/i16 (storage). Also the abstract heap
    // and cast names — all plain identifiers, distinguished in queries.
    primitive_type: $ => $.identifier,

    // & ?? !? heap_type   (parser.mly:470-481)
    reference_type: $ => seq(
      '&',
      optional(field('nullable', '?')),
      optional(field('exact', '!')),
      field('heap', $._heap_type),
    ),

    _heap_type: $ => choice('cont', alias($.identifier, $.type_identifier)),

    _type_name: $ => alias($.identifier, $.type_identifier),

    // cast_type (parser.mly:489-497): a value/cast name, a reference type, or
    // `& ?? fn functype`.
    _cast_type: $ => choice(
      $.primitive_type,
      $.reference_type,
      seq('&', optional('?'), 'fn', $.function_type),
    ),

    // ( params ) (-> results)?   (parser.mly:624-626)
    function_type: $ => seq(
      field('parameters', $.parameter_list),
      optional(seq('->', field('result', $._result_type))),
    ),

    parameter_list: $ => seq(
      '(',
      sepByTrailing(',', $.parameter),
      ')',
    ),

    parameter: $ => choice(
      seq(field('name', $.identifier), ':', field('type', $._value_type)),
      field('type', $._value_type),
    ),

    _result_type: $ => choice(
      seq('(', ')'),
      $._value_type,
      seq('(', sepBy1Trailing(',', $._value_type), ')'),
    ),

    // Struct/array/func/cont composite types (parser.mly:532-548).
    struct_type: $ => seq(
      '{',
      choice(
        '..',
        seq('..', ',', sepByTrailing(',', $.struct_type_field)),
        sepByTrailing(',', $.struct_type_field),
      ),
      '}',
    ),

    struct_type_field: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $.field_type),
    ),

    field_type: $ => seq(
      optional('mut'),
      field('type', $._storage_type),
    ),

    _storage_type: $ => choice($.reference_type, $.primitive_type),

    array_type: $ => seq('[', $.field_type, ']'),

    _composite_type: $ => choice(
      $.struct_type,
      seq('fn', $.function_type),
      $.array_type,
      seq('cont', field('type', $._type_name)),
    ),

    // type name (: super)? = open? (describes X)? (descriptor Y)? comp ;
    type_definition: $ => seq(
      'type',
      field('name', $.identifier),
      optional(seq(':', field('supertype', $._type_name))),
      '=',
      optional('open'),
      optional(seq('describes', field('describes', $._type_name))),
      optional(seq('descriptor', field('descriptor', $._type_name))),
      field('body', $._composite_type),
      ';',
    ),

    rec_type: $ => seq('rec', '{', repeat($.type_definition), '}'),

    // ---------------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------------

    _expression: $ => choice(
      $._plaininstr,
      $._block_instruction,
    ),

    _plaininstr: $ => choice(
      $.null,
      $.hole,
      $.identifier,
      $.path_expression,
      $.parenthesized_expression,
      $.sequence_expression,
      $.call_expression,
      $.char_literal,
      $.string_literal,
      $.typed_string_expression,
      $.integer_literal,
      $.float_literal,
      $.inf,
      $.nan,
      $.struct_expression,
      $.struct_default_expression,
      $.array_expression,
      $.tee_expression,
      $.cast_expression,
      $.cast_desc_expression,
      $.test_expression,
      $.struct_get_expression,
      $.get_descriptor_expression,
      $.struct_set_expression,
      $.binary_expression,
      $.unary_expression,
      $.non_null_expression,
      $.array_get_expression,
      $.select_expression,
      $.branch_expression,
      $.cont_new_expression,
      $.cont_bind_expression,
      $.suspend_expression,
      $.resume_expression,
      $.resume_throw_expression,
      $.resume_throw_ref_expression,
      $.switch_expression,
    ),

    null: $ => 'null',
    hole: $ => '_',
    inf: $ => 'inf',
    nan: $ => 'nan',

    path_expression: $ => prec(PREC.postfix, seq(
      field('root', $.identifier),
      '::',
      field('member', $.identifier),
    )),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    sequence_expression: $ => seq(
      '(',
      $._expression,
      ',',
      sepByTrailing(',', $._expression),
      ')',
    ),

    call_expression: $ => prec(PREC.postfix, seq(
      field('function', $._expression),
      field('arguments', $.argument_list),
    )),

    argument_list: $ => seq('(',
      sepByTrailing(',', choice($.labelled_argument, $._expression)), ')'),

    // A labelled immediate argument of a memory access:
    // m.store32(p, v, offset: 16, align: 1), m.v128_load8_lane(p, v, lane: 3).
    labelled_argument: $ => seq(
      field('label', $.identifier), ':', field('value', $._expression)),

    typed_string_expression: $ => prec(PREC.postfix, seq(
      field('type', $.identifier),
      '#',
      field('value', $.string_literal),
    )),

    // {} | { fields } | { x | fields } | { descriptor(d) | fields }.
    struct_expression: $ => prec(PREC.block, seq(
      '{',
      optional(choice(
        seq(field('base', choice($._expression, $.descriptor_operand)), '|',
          sepByTrailing(',', $.field_initializer)),
        sepBy1Trailing(',', $.field_initializer),
      )),
      '}',
    )),

    // { x | .. } | { .. } | { descriptor(d) | .. }
    struct_default_expression: $ => prec(PREC.block, seq(
      '{',
      optional(seq(field('base', choice($._expression, $.descriptor_operand)), '|')),
      '..',
      '}',
    )),

    field_initializer: $ => choice(
      seq(field('name', $.identifier), ':', field('value', $._expression)),
      field('name', $.identifier), // punning: {x} == {x: x}
    ),

    descriptor_operand: $ => seq('descriptor', '(', $._expression, ')'),

    // [ body ] | [ t | body ]
    array_expression: $ => prec(PREC.block, seq(
      '[',
      optional(seq(field('type', $.identifier), '|')),
      optional($._array_body),
      ']',
    )),

    _array_body: $ => choice(
      sepBy1Trailing(',', $._expression),
      seq(field('element', $._expression), ';', field('length', $._expression)),
      seq('..', ';', field('length', $._expression)),
      seq(field('data', $.identifier), '@', field('offset', $._expression),
        ';', field('length', $._expression)),
    ),

    tee_expression: $ => prec.right(PREC.assign, seq(
      field('name', $.identifier),
      ':=',
      field('value', $._expression),
    )),

    cast_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._expression),
      'as',
      field('type', $._cast_type),
    )),

    cast_desc_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._expression),
      'as',
      optional('?'),
      field('descriptor', $.descriptor_operand),
    )),

    test_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._expression),
      'is',
      field('type', $.reference_type),
    )),

    struct_get_expression: $ => prec(PREC.postfix, seq(
      field('value', $._expression),
      '.',
      field('field', $.identifier),
    )),

    get_descriptor_expression: $ => prec(PREC.postfix, seq(
      field('value', $._expression),
      '.',
      'descriptor',
    )),

    struct_set_expression: $ => prec.right(PREC.assign, seq(
      field('target', $.struct_get_expression),
      '=',
      field('value', $._expression),
    )),

    array_get_expression: $ => prec(PREC.postfix, seq(
      field('array', $._expression),
      '[',
      field('index', $._expression),
      ']',
    )),

    non_null_expression: $ => prec(PREC.postfix, seq($._expression, '!')),

    select_expression: $ => prec.right(PREC.ternary, seq(
      field('condition', $._expression),
      '?',
      field('consequence', $._expression),
      ':',
      field('alternative', $._expression),
    )),

    unary_expression: $ => prec(PREC.unary, seq(
      field('operator', choice('!', '-', '+')),
      field('operand', $._expression),
    )),

    binary_expression: $ => {
      const table = [
        // The compiler makes comparisons nonassoc (chaining is a type error);
        // tree-sitter has no nonassoc, so we accept chains as left-associative.
        [PREC.compare, choice('==', '!=', '<', '<s', '<u', '>', '>s', '>u',
          '<=', '<=s', '<=u', '>=', '>=s', '>=u'), 'left'],
        [PREC.or, '|', 'left'],
        [PREC.xor, '^', 'left'],
        [PREC.and, '&', 'left'],
        [PREC.shift, choice('<<', '>>s', '>>u'), 'left'],
        [PREC.add, choice('+', '-'), 'left'],
        [PREC.mul, choice('*', '/', '/s', '/u', '%s', '%u'), 'left'],
      ];
      return choice(...table.map(([p, op, assoc]) => {
        const rule = seq(
          field('left', $._expression),
          field('operator', op),
          field('right', $._expression),
        );
        return assoc === 'left' ? prec.left(p, rule)
          : assoc === 'right' ? prec.right(p, rule)
            : prec(p, rule);
      }));
    },

    // Operand-carrying conditional branches (parser.mly:598-605).
    branch_expression: $ => prec.right(PREC.branch, seq(
      repeat($.attribute),
      choice(
        seq('br_if', field('label', $.label), field('value', $._expression)),
        seq('br_on_null', field('label', $.label), field('value', $._expression)),
        seq('br_on_non_null', field('label', $.label), field('value', $._expression)),
        seq('br_on_cast', field('label', $.label),
          field('type', $.reference_type), field('value', $._expression)),
        seq('br_on_cast_fail', field('label', $.label),
          field('type', $.reference_type), field('value', $._expression)),
        seq('br_on_cast', field('label', $.label), optional('?'),
          field('descriptor', $.descriptor_operand), field('value', $._expression)),
        seq('br_on_cast_fail', field('label', $.label), optional('?'),
          field('descriptor', $.descriptor_operand), field('value', $._expression)),
      ),
    )),

    // Stack-switching / continuation ops (parser.mly:887-900).
    cont_new_expression: $ => seq('cont_new', field('type', $._type_name),
      '(', $._expression, ')'),
    cont_bind_expression: $ => seq('cont_bind', field('source', $._type_name),
      field('target', $._type_name), $.argument_list),
    suspend_expression: $ => seq('suspend', field('tag', $._type_name), $.argument_list),
    resume_expression: $ => seq('resume', field('type', $._type_name),
      $.on_clauses, $.argument_list),
    resume_throw_expression: $ => seq('resume_throw', field('type', $._type_name),
      field('tag', $._type_name), $.on_clauses, $.argument_list),
    resume_throw_ref_expression: $ => seq('resume_throw_ref', field('type', $._type_name),
      $.on_clauses, $.argument_list),
    switch_expression: $ => seq('switch', field('type', $._type_name),
      field('tag', $._type_name), $.argument_list),

    on_clauses: $ => seq('[', sepByTrailing(',', $.on_clause), ']'),
    on_clause: $ => choice(
      seq(field('tag', $.identifier), '->', field('label', $.label)),
      seq(field('tag', $.identifier), '->', 'switch'),
    ),

    // ---------------------------------------------------------------------
    // Statements & blocks
    // ---------------------------------------------------------------------

    block: $ => seq(optional($.block_label), $._braced_block),

    _braced_block: $ => seq('{', repeat($._block_item), '}'),

    block_label: $ => seq($.label, ':'),

    _block_item: $ => choice(
      ';',
      seq($._statement, ';'),
      $._block_instruction,
      $._conditional_statement,
    ),

    _statement: $ => choice(
      $._plaininstr,
      $.nop,
      $.unreachable,
      $.assignment_statement,
      $.compound_assignment_statement,
      $.discard_statement,
      $.let_statement,
      $.br_statement,
      $.br_table_statement,
      $.return_statement,
      $.throw_statement,
      $.throw_ref_statement,
      $.become_statement,
      $.array_set_statement,
    ),

    nop: $ => 'nop',
    unreachable: $ => 'unreachable',

    assignment_statement: $ => seq(
      field('name', $.identifier),
      '=',
      field('value', $._expression),
    ),

    compound_assignment_statement: $ => seq(
      field('name', $.identifier),
      field('operator', choice(
        '+=', '-=', '*=', '/=', '/s=', '/u=', '%s=', '%u=',
        '&=', '|=', '^=', '<<=', '>>s=', '>>u=',
      )),
      field('value', $._expression),
    ),

    discard_statement: $ => seq(
      '_',
      optional(seq(':', field('type', $._value_type))),
      '=',
      field('value', $._expression),
    ),

    let_statement: $ => seq(
      'let',
      choice(
        seq(field('pattern', $._pattern),
          optional(seq(':', field('type', $._value_type))),
          optional(seq('=', field('value', $._expression)))),
        seq('(', sepByTrailing(',', $.let_binding), ')',
          optional(seq('=', field('value', $._expression)))),
      ),
    ),

    let_binding: $ => seq(
      field('pattern', $._pattern),
      optional(seq(':', field('type', $._value_type))),
    ),

    _pattern: $ => choice($.identifier, alias('_', $.wildcard)),

    br_statement: $ => prec.right(PREC.branch, seq(
      'br',
      field('label', $.label),
      optional(field('value', $._expression)),
    )),

    br_table_statement: $ => seq(
      'br_table',
      '[',
      repeat($.label),
      'else',
      field('default', $.label),
      ']',
      field('value', $._expression),
    ),

    return_statement: $ => prec.right(PREC.branch, seq(
      'return',
      optional(field('value', $._expression)),
    )),

    throw_statement: $ => prec.right(PREC.branch, seq(
      'throw',
      field('tag', $._type_name),
      optional(field('value', $._expression)),
    )),

    throw_ref_statement: $ => seq('throw_ref', field('value', $._expression)),

    become_statement: $ => seq(
      'become',
      field('function', $._expression),
      $.argument_list,
    ),

    array_set_statement: $ => seq(
      field('array', $._expression),
      '[',
      field('index', $._expression),
      ']',
      '=',
      field('value', $._expression),
    ),

    // Block-shaped instructions: no trailing `;` needed (parser.mly:745-785).
    _block_instruction: $ => choice(
      $.do_expression,
      $.while_expression,
      $.loop_expression,
      $.if_expression,
      $.match_expression,
      $.dispatch_expression,
      $.try_table_expression,
      $.try_expression,
    ),

    do_expression: $ => seq(
      optional($.block_label),
      'do',
      optional(field('type', $._block_type)),
      field('body', $._braced_block),
    ),

    while_expression: $ => seq(
      optional($.block_label),
      'while',
      field('condition', $._expression),
      optional(seq(':', '(', field('step', $._statement), ')')),
      field('body', $._braced_block),
    ),

    loop_expression: $ => seq(
      optional($.block_label),
      'loop',
      optional(field('type', $._block_type)),
      field('body', $._braced_block),
    ),

    if_expression: $ => prec.right(seq(
      repeat($.attribute),
      optional($.block_label),
      'if',
      field('condition', $._expression),
      optional(seq('=>', field('type', $._block_type))),
      field('consequence', $._braced_block),
      optional(seq('else', field('alternative', $._braced_block))),
    )),

    match_expression: $ => seq(
      'match',
      field('value', $._expression),
      '{',
      repeat(choice($.match_arm, ';')),
      field('default', $.match_default),
      '}',
    ),

    match_arm: $ => seq(
      field('pattern', $._match_pattern),
      '=>',
      field('body', $._braced_block),
    ),

    _match_pattern: $ => choice(
      seq(field('name', $.identifier), ':', field('type', $.reference_type)),
      field('type', $.reference_type),
      'null',
    ),

    match_default: $ => seq('_', '=>', field('body', $._braced_block)),

    dispatch_expression: $ => seq(
      'dispatch',
      field('index', $._expression),
      '[',
      repeat($.label),
      'else',
      field('default', $.label),
      ']',
      '{',
      repeat(choice($.dispatch_arm, ';')),
      '}',
    ),

    dispatch_arm: $ => seq(
      field('label', $.label),
      ':',
      field('body', $._braced_block),
    ),

    try_table_expression: $ => seq(
      optional($.block_label),
      'try',
      optional(field('type', $._block_type)),
      field('body', $._braced_block),
      'catch',
      '[',
      sepByTrailing(',', $.catch_clause),
      ']',
    ),

    catch_clause: $ => choice(
      seq(field('tag', $.identifier), '->', field('label', $.label)),
      seq(field('tag', $.identifier), '&', '->', field('label', $.label)),
      seq('_', '->', field('label', $.label)),
      seq('_', '&', '->', field('label', $.label)),
    ),

    try_expression: $ => seq(
      optional($.block_label),
      'try',
      optional(field('type', $._block_type)),
      field('body', $._braced_block),
      'catch',
      '{',
      repeat(choice($.legacy_catch, ';')),
      optional(seq($.legacy_catch_all, repeat(';'))),
      '}',
    ),

    legacy_catch: $ => seq(
      field('tag', $.identifier),
      '=>',
      field('body', $._braced_block),
    ),

    legacy_catch_all: $ => seq('_', '=>', field('body', $._braced_block)),

    // block_type (parser.mly:674-679): a parenthesized param/result signature,
    // or a bare single value type.
    _block_type: $ => choice(
      seq('(', sepByTrailing(',', $._value_type), ')',
        optional(seq('->', field('result', $._result_type)))),
      $._value_type,
    ),

    // Statement-level conditional compilation (parser.mly:1012-1014). Kept as
    // sibling nodes; not paired with a following `#[else]`.
    _conditional_statement: $ => choice(
      $.conditional_if_statement,
      $.conditional_else_statement,
    ),

    conditional_if_statement: $ => seq(
      '#', '[', 'if', '(', field('condition', $._condition), ')', ']',
      field('body', $._braced_block),
    ),

    conditional_else_statement: $ => seq(
      '#', '[', 'else', ']',
      field('body', $._braced_block),
    ),

    // ---------------------------------------------------------------------
    // Module fields
    // ---------------------------------------------------------------------

    _module_field: $ => choice(
      $.rec_type,
      $.type_definition,
      $.inner_attribute,
      $._attributed_definition,
      $.import_field,
      $.import_group,
      $.conditional_if_field,
      $.conditional_else_field,
    ),

    _attributed_definition: $ => seq(repeat($.attribute), $._definition),

    _definition: $ => choice(
      $.function_definition,
      $.global_definition,
      $.memory_definition,
      $.data_definition,
      $.table_definition,
      $.element_definition,
      $.tag_definition,
    ),

    function_definition: $ => seq(
      'fn',
      field('name', $.identifier),
      optional('!'),
      optional(seq(':', optional('!'), field('type', $._type_name))),
      optional(field('parameters', $.parameter_list)),
      optional(seq('->', field('result', $._result_type))),
      field('body', $.block),
    ),

    global_definition: $ => seq(
      field('kind', choice('let', 'const')),
      field('name', $.identifier),
      optional(seq(':', field('type', $._value_type))),
      '=',
      field('value', $._expression),
      ';',
    ),

    tag_definition: $ => seq(
      'tag',
      field('name', $.identifier),
      optional(seq(':', field('type', $._type_name))),
      optional(field('signature', $.function_type)),
      ';',
    ),

    memory_definition: $ => seq(
      'memory',
      field('name', $.identifier),
      ':',
      field('address_type', $.identifier),
      optional($.limits),
      optional($.page_size),
      optional('shared'),
      choice(';', seq('{', repeat($.memory_data_item), '}')),
    ),

    memory_data_item: $ => seq(
      'data',
      field('name', $._data_name),
      '@', '[', field('offset', $._expression), ']',
      optional(seq('=', field('init', $.data_init))),
      ';',
    ),

    limits: $ => seq(
      '[',
      field('min', $.integer_literal),
      optional(seq(',', field('max', $.integer_literal))),
      ']',
    ),

    page_size: $ => seq('pagesize', $.integer_literal),

    data_definition: $ => seq(
      'data',
      field('name', $._data_name),
      optional(seq('@', field('memory', $.identifier),
        '[', field('offset', $._expression), ']')),
      optional(seq('=', field('init', $.data_init))),
      ';',
    ),

    _data_name: $ => choice(alias('_', $.wildcard), $.identifier),

    data_init: $ => sepBy1Trailing(',', $._data_element),

    _data_element: $ => choice(
      $.string_literal,
      $.data_run,
    ),

    data_run: $ => seq(
      '[',
      field('type', $.identifier),
      ':',
      sepByTrailing(',', $._data_run_item),
      ']',
    ),

    _data_run_item: $ => choice(
      $.data_number,
      $.data_vector,
    ),

    data_vector: $ => seq(
      field('shape', $.identifier),
      '(',
      sepByTrailing(',', $.data_number),
      ')',
    ),

    data_number: $ => seq(
      optional(choice('+', '-')),
      choice($.integer_literal, $.float_literal, 'inf', 'nan'),
    ),

    table_definition: $ => seq(
      'table',
      field('name', $.identifier),
      ':',
      optional(field('address_type', $.identifier)),
      field('type', $.reference_type),
      optional($.limits),
      optional(seq('=', field('init', $._expression))),
      ';',
    ),

    element_definition: $ => seq(
      'elem',
      field('name', $.identifier),
      ':',
      field('type', $.reference_type),
      optional(seq('@', field('table', $.identifier),
        '[', field('offset', $._expression), ']')),
      '=',
      '[', sepByTrailing(',', $._expression), ']',
      ';',
    ),

    // import "mod" item   |   import "mod" { item; … }
    import_field: $ => seq(
      'import',
      field('module', $.string_literal),
      field('item', $.import_item),
    ),

    import_group: $ => seq(
      'import',
      field('module', $.string_literal),
      '{',
      repeat(choice($.import_item, ';')),
      '}',
    ),

    import_item: $ => seq(
      repeat($.attribute),
      $._import_kind,
      ';',
    ),

    _import_kind: $ => choice(
      $.import_function,
      $.import_global,
      $.import_tag,
      $.import_memory,
      $.import_table,
    ),

    import_function: $ => seq(
      'fn',
      field('name', $.identifier),
      optional('!'),
      optional(seq(':', optional('!'), field('type', $._type_name))),
      optional(field('parameters', $.parameter_list)),
      optional(seq('->', field('result', $._result_type))),
    ),

    import_global: $ => seq(
      field('kind', choice('let', 'const')),
      field('name', $.identifier),
      ':',
      field('type', $._value_type),
    ),

    import_tag: $ => seq(
      'tag',
      field('name', $.identifier),
      optional(seq(':', field('type', $._type_name))),
      optional(field('signature', $.function_type)),
    ),

    import_memory: $ => seq(
      'memory',
      field('name', $.identifier),
      ':',
      field('address_type', $.identifier),
      optional($.limits),
      optional($.page_size),
      optional('shared'),
    ),

    import_table: $ => seq(
      'table',
      field('name', $.identifier),
      ':',
      optional(field('address_type', $.identifier)),
      field('type', $.reference_type),
      optional($.limits),
    ),

    // ---------------------------------------------------------------------
    // Attributes & conditions
    // ---------------------------------------------------------------------

    attribute: $ => seq(
      '#', '[',
      field('name', $._attribute_name),
      optional(seq('=', field('value', $._expression))),
      optional(seq(',', 'if', field('guard', $._condition))),
      ']',
    ),

    _attribute_name: $ => choice($.identifier, 'import'),

    inner_attribute: $ => seq(
      '#', '!', '[',
      field('name', $.identifier),
      optional(seq('=', field('value', $._expression))),
      ']',
    ),

    conditional_if_field: $ => seq(
      '#', '[', 'if', '(', field('condition', $._condition), ')', ']',
      '{', repeat($._module_item), '}',
    ),

    conditional_else_field: $ => seq(
      '#', '[', 'else', ']',
      '{', repeat($._module_item), '}',
    ),

    _condition: $ => choice(
      $.identifier,
      $.condition_comparison,
      $.condition_combinator,
    ),

    condition_comparison: $ => seq(
      field('name', $.identifier),
      field('operator', choice('=', '!=', '<', '>', '<=', '>=')),
      field('value', $._condition_literal),
    ),

    condition_combinator: $ => seq(
      field('kind', choice('all', 'any', 'not')),
      '(',
      sepByTrailing(',', $._condition),
      ')',
    ),

    _condition_literal: $ => choice(
      seq('(', $.integer_literal, ',', $.integer_literal, ',', $.integer_literal, ')'),
      $.string_literal,
    ),
  },
});

/** Zero or more `rule` separated by `sep`, with optional trailing separator. */
function sepByTrailing(sep, rule) {
  return optional(sepBy1Trailing(sep, rule));
}

/** One or more `rule` separated by `sep`, with optional trailing separator. */
function sepBy1Trailing(sep, rule) {
  return seq(rule, repeat(seq(sep, rule)), optional(sep));
}
