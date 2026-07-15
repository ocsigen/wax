#include "tree_sitter/parser.h"

// External scanner for Wax's nested block comments (`/* ... /* ... */ ... */`).
// Balanced nesting is not a regular language, so it cannot be expressed as a
// `token()` regex; a depth counter is required. Mirrors `comment_rec` in
// src/lib-wax/lexer.ml.

enum TokenType {
  BLOCK_COMMENT,
};

void *tree_sitter_wax_external_scanner_create(void) { return NULL; }
void tree_sitter_wax_external_scanner_destroy(void *payload) {}
unsigned tree_sitter_wax_external_scanner_serialize(void *payload, char *buffer) {
  return 0;
}
void tree_sitter_wax_external_scanner_deserialize(void *payload, const char *buffer,
                                                  unsigned length) {}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

bool tree_sitter_wax_external_scanner_scan(void *payload, TSLexer *lexer,
                                           const bool *valid_symbols) {
  if (!valid_symbols[BLOCK_COMMENT]) return false;

  // Skip whitespace the grammar treats as extras before the comment start.
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\n' || lexer->lookahead == '\r') {
    lexer->advance(lexer, true);
  }

  if (lexer->lookahead != '/') return false;
  advance(lexer);
  if (lexer->lookahead != '*') return false;
  advance(lexer);

  unsigned depth = 1;
  for (;;) {
    switch (lexer->lookahead) {
      case '\0':
        return false; // EOF inside an unterminated comment
      case '*':
        advance(lexer);
        if (lexer->lookahead == '/') {
          advance(lexer);
          if (--depth == 0) {
            lexer->result_symbol = BLOCK_COMMENT;
            lexer->mark_end(lexer);
            return true;
          }
        }
        break;
      case '/':
        advance(lexer);
        if (lexer->lookahead == '*') {
          advance(lexer);
          depth++;
        }
        break;
      default:
        advance(lexer);
        break;
    }
  }
}
