(lang dune 3.20)
(using menhir 3.0)
; The wax tool's completion/manpage install rule produces a whole directory
; (src/bin/dune); directory targets need this extension.
(using directory-targets 0.1)
(name wax)
(version "0.1.1~dev")
(generate_opam_files true)

(authors "Jérôme Vouillon")
(maintainers "Jérôme Vouillon")
(source (github ocsigen/wax))
(documentation "https://ocsigen.org/wax/")
(license "Apache-2.0")

(package
  (name wax-lib)
  (synopsis "Libraries for Wax, a Rust-like syntax for WebAssembly")
  (description "The parsing, type-checking and format-conversion libraries behind the Wax toolchain (bidirectional Wax <-> Wasm Text <-> Wasm Binary).")
  (depends
    (ocaml (>= 4.14))
    ; 3.3 adds the byte-offset position API (lexing_bytes_position_start/curr)
    ; the lexers use; still compatible with OCaml 4.14.
    (sedlex (>= 3.3))
    (menhir (and :build (>= 20220210)))
    (menhirLib (>= 20220210))
    (re (>= 1.10.0))
    (yojson (>= 2.0.0))
    (uucp (and :with-dev-setup (>= 16.0.0)))
  )
)

(package
  (name wax)
  (synopsis "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly")
  (description "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly. Capabilities: Formatting, Type Checking, Syntax Conversion (Wax <-> Wasm Text <-> Wasm Binary).")
  (depends
    (ocaml (>= 4.14))
    (wax-lib (= :version))
    (yojson (>= 2.0.0))
    ; 2.0 for the Conv.make/Arg.Completion API and the completion protocol in
    ; Cmd.eval, plus `cmdliner install tool-support` at build time.
    (cmdliner (>= 2.0.0))
    ; The `wax lsp` language server (src/lib-lsp): protocol types and framing.
    ; 1.17 has the 3.17 `positionEncoding` capability the server advertises;
    ; 1.26 is the floor that has `Lsp.Uri.of_string` (used for diagnostics URIs).
    (lsp (>= 1.26.0))
    (jsonrpc (>= 1.26.0))
    ; Embeds the version reported by `wax --version` (git tag at build time).
    (dune-build-info (>= 3.0.0))
    ; The cram CLI tests (lsp.t, feature-attribute.t, source-map-mappings.t)
    ; drive the binary through python3 helpers.
    (conf-python-3 :with-test)
  )
)
