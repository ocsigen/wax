;;; wax-ts-mode.el --- Tree-sitter major mode for Wax -*- lexical-binding: t; -*-

;; Author: Jérôme Vouillon
;; Version: 0.1.0
;; Keywords: languages, wax, webassembly
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A major mode for the Wax language (a Rust-like syntax for WebAssembly),
;; built on Emacs's built-in tree-sitter support (`treesit', Emacs 29+) and the
;; `tree-sitter-wax' grammar.
;;

;; Setup:
;;   M-x wax-ts-install-grammar RET
;; then open a .wax file (or simply open a .wax file and follow the prompt).

;;; Code:

(require 'treesit)

(defgroup wax nil
  "Major mode for the Wax language."
  :group 'languages)

(defcustom wax-ts-mode-indent-offset 4
  "Number of spaces for each indentation step in `wax-ts-mode'."
  :type 'integer
  :safe #'integerp)

(defcustom wax-format-command '("wax" "format" "-f" "wax")
  "Command used by `wax-format-buffer' to reformat Wax source.
It receives the buffer on standard input and must write the formatted
result to standard output."
  :type '(repeat string))

;; The bare-word keywords of the language (lexer.ml). `import' heads grouped
;; imports; the rest declare or control.
(defvar wax-ts-mode--keywords
  '("fn" "let" "const" "type" "rec" "memory" "data" "table" "elem" "import"
    "tag" "cont" "cont_new" "cont_bind" "suspend" "resume" "resume_throw"
    "resume_throw_ref" "switch" "if" "else" "match" "dispatch" "do" "while"
    "loop" "return" "become" "try" "catch" "throw" "throw_ref" "br" "br_if"
    "br_table" "br_on_null" "br_on_non_null" "br_on_cast" "br_on_cast_fail")
  "Wax keywords for font-locking.")

(defvar wax-ts-mode--modifiers
  '("mut" "open" "shared" "pagesize" "descriptor" "describes")
  "Wax storage/type modifier keywords.")

(defvar wax-ts-mode--font-lock-rules
  (treesit-font-lock-rules
   :language 'wax
   :feature 'comment
   '([(line_comment) (block_comment)] @font-lock-comment-face)

   :language 'wax
   :feature 'string
   '((string_literal) @font-lock-string-face
     (char_literal) @font-lock-string-face)

   :language 'wax
   :feature 'escape
   '((escape_sequence) @font-lock-escape-face)

   ;; A generic variable face first, so the more specific features below win.
   :language 'wax
   :feature 'variable
   '((identifier) @font-lock-variable-use-face)

   :language 'wax
   :feature 'keyword
   `([,@wax-ts-mode--keywords] @font-lock-keyword-face
     [,@wax-ts-mode--modifiers] @font-lock-keyword-face
     ["as" "is"] @font-lock-keyword-face)

   :language 'wax
   :feature 'constant
   '([(null) (nop) (unreachable) (inf) (nan)] @font-lock-constant-face
     (label) @font-lock-constant-face)

   :language 'wax
   :feature 'number
   '((integer_literal) @font-lock-number-face
     (float_literal) @font-lock-number-face)

   :language 'wax
   :feature 'type
   '((primitive_type) @font-lock-type-face
     (type_identifier) @font-lock-type-face
     (type_definition name: (identifier) @font-lock-type-face))

   :language 'wax
   :feature 'definition
   '((function_definition name: (identifier) @font-lock-function-name-face)
     (import_function name: (identifier) @font-lock-function-name-face)
     (parameter name: (identifier) @font-lock-variable-name-face))

   :language 'wax
   :feature 'function
   '((call_expression function: (identifier) @font-lock-function-call-face)
     (become_statement function: (identifier) @font-lock-function-call-face))

   :language 'wax
   :feature 'property
   '((field_initializer name: (identifier) @font-lock-property-use-face)
     (struct_get_expression field: (identifier) @font-lock-property-use-face)
     (struct_type_field name: (identifier) @font-lock-property-name-face))

   :language 'wax
   :feature 'attribute
   '((attribute name: (identifier) @font-lock-preprocessor-face)
     (inner_attribute name: (identifier) @font-lock-preprocessor-face))

   :language 'wax
   :feature 'bracket
   '(["(" ")" "{" "}" "[" "]"] @font-lock-bracket-face)

   :language 'wax
   :feature 'delimiter
   '(["," ";" ":" "::" "#" "|"] @font-lock-delimiter-face)

   :language 'wax
   :feature 'operator
   '(["+" "-" "*" "/" "/s" "/u" "%s" "%u" "&" "|" "^" "<<" ">>s" ">>u"
      "==" "!=" "<" "<s" "<u" ">" ">s" ">u" "<=" "<=s" "<=u" ">=" ">=s" ">=u"
      "=" ":=" "!" "?" "->" "=>" ".." "@"]
     @font-lock-operator-face))
  "Tree-sitter font-lock settings for `wax-ts-mode'.")

;; Feature levels, applied up to `treesit-font-lock-level' (default 3). Order
;; also sets override precedence: `variable' precedes the specific captures.
(defvar wax-ts-mode--font-lock-feature-list
  '((comment definition)
    (keyword string type)
    (constant number escape function property attribute)
    (variable operator bracket delimiter))
  "Font-lock feature list for `wax-ts-mode'.")

(defvar wax-ts-mode--indent-rules
  `((wax
     ((node-is "}") parent-bol 0)
     ((node-is "]") parent-bol 0)
     ((node-is ")") parent-bol 0)
     ((parent-is "block") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "struct_type") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "struct_expression") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "match_expression") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "dispatch_expression") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "parameter_list") parent-bol wax-ts-mode-indent-offset)
     ((parent-is "argument_list") parent-bol wax-ts-mode-indent-offset)
     (catch-all parent-bol 0)))
  "Tree-sitter indentation rules for `wax-ts-mode'.")

(defun wax-format-buffer ()
  "Reformat the current buffer with `wax-format-command'.
On a formatter error the buffer is left unchanged and the error is shown."
  (interactive)
  ;; `call-process-region' sends the buffer on stdin; stdout goes to a buffer,
  ;; but its stderr destination must be a file, so route it through a temp file.
  (let ((out (generate-new-buffer " *wax-format-output*"))
        (errfile (make-temp-file "wax-format-err")))
    (unwind-protect
        (let ((status (apply #'call-process-region (point-min) (point-max)
                             (car wax-format-command) nil (list out errfile) nil
                             (cdr wax-format-command))))
          (if (eq status 0)
              (let ((pos (point)))
                (replace-buffer-contents out)
                (goto-char (min pos (point-max))))
            (message "wax format: %s"
                     (string-trim
                      (with-temp-buffer
                        (insert-file-contents errfile)
                        (buffer-string))))))
      (kill-buffer out)
      (delete-file errfile))))

(defvar wax-ts-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; C-style comments (// and /* */)
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\n "> b" table)
    ;; Symbol constituents (so variables with underscores are treated as one word)
    (modify-syntax-entry ?_ "_" table)
    table)
  "Syntax table for `wax-ts-mode'.")

;;;###autoload
(defun wax-ts-install-grammar ()
  "Install or update the Tree-sitter grammar for Wax."
  (interactive)
  (let ((treesit-language-source-alist
         (cons '(wax "https://github.com/ocsigen/wax" "main" "tree-sitter-wax/src")
               treesit-language-source-alist)))
    (treesit-install-language-grammar 'wax)))

;;;###autoload
(define-derived-mode wax-ts-mode prog-mode "Wax"
  "Major mode for editing Wax, powered by tree-sitter."
  :group 'wax

  (unless (treesit-ready-p 'wax t)
    (when (y-or-n-p "Wax tree-sitter grammar is not installed. Install it now? ")
      (wax-ts-install-grammar)))

  (if (treesit-ready-p 'wax)
      (progn
        (treesit-parser-create 'wax)
        (setq-local treesit-font-lock-settings wax-ts-mode--font-lock-rules)
        (setq-local treesit-font-lock-feature-list wax-ts-mode--font-lock-feature-list)
        (setq-local treesit-simple-indent-rules wax-ts-mode--indent-rules)
        (setq-local comment-start "// ")
        (setq-local comment-end "")
        (setq-local treesit-defun-type-regexp "function_definition")
        (setq-local treesit-simple-imenu-settings
                    '(("Function" "\\`function_definition\\'" nil nil)
                      ("Type" "\\`type_definition\\'" nil nil)))
        (treesit-major-mode-setup))
    (message "Wax tree-sitter grammar is required for wax-ts-mode to fully function.")))

;;;###autoload
(when (fboundp 'treesit-ready-p)
  (add-to-list 'auto-mode-alist '("\\.wax\\'" . wax-ts-mode)))

;; Automatically register the language server with Eglot if Eglot is loaded
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(wax-ts-mode . ("wax" "lsp"))))

(provide 'wax-ts-mode)
;;; wax-ts-mode.el ends here
