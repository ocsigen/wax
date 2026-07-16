# Releasing

Wax ships three independently-versioned artifacts, each with its own version
number and its own release trigger:

| Component | Published as | Version lives in | Release trigger |
|-----------|--------------|------------------|-----------------|
| `wax` toolchain | native binaries on GitHub Releases + `@wax-wasm/wax` on npm + `wax`/`wax-lib` on opam | `(version …)` in `dune-project` | push a `vX.Y.Z` tag |
| VS Code extension | `wax-wasm.wax` on the VS Code Marketplace | `editors/vscode/package.json` | manual (`vsce publish`) |
| tree-sitter grammar | `tree-sitter-wax` on npm | `tree-sitter.json` / `package.json` / `Cargo.toml` | push a `grammar-vX.Y.Z` tag |

The version numbers are **not** kept in lockstep; release each component on its
own cadence.

## Two rules that apply to every tagged release

1. **Push `main` before you push a tag.** A tag-triggered workflow checks out
   and runs the workflow file *and* the code at the tagged commit. If the commit
   is not on the remote, or the tag points at a stale commit, the release runs
   against the wrong tree.
2. **To re-run a release after fixing something, move the tag:**
   `git tag -f <tag> && git push --force origin <tag>`.

## One-time setup (already done, listed for reference)

- The repository is **public** (npm trusted publishing and provenance require it).
- **Trusted publishers** are configured on npmjs.com, so no `NPM_TOKEN` secret is
  needed:
  - `@wax-wasm/wax` → workflow `npm-package.yml`
  - `tree-sitter-wax` → workflow `tree-sitter-publish.yml`
- The VS Code Marketplace publisher `wax-wasm` exists and you have a Personal
  Access Token for it (`vsce login wax-wasm`, or set `VSCE_PAT`).

---

## Releasing the `wax` toolchain (`vX.Y.Z`)

One tag builds and publishes everything: the native binaries, the npm package,
and the version stamped into `wax --version`.

1. Bump the version in `dune-project`: `(version X.Y.Z)`.
2. `dune build`: regenerates `wax.opam` and `wax-lib.opam` with the new version.
3. `dune runtest`: must pass (includes the docs-examples cram test).
4. Sanity check: `dune exec wax -- --version` should print `X.Y.Z`.
5. Commit `dune-project`, `wax.opam`, `wax-lib.opam`.
6. `git push origin main`.
7. `git tag vX.Y.Z && git push origin vX.Y.Z`.
8. Watch the Actions run:
   - **Release binaries** (`release.yml`) attaches the native binaries (static
     Linux x86_64, macOS arm64/x86_64, Windows x86_64) and `SHA256SUMS` to a
     GitHub Release named `vX.Y.Z`.
   - **npm package** (`npm-package.yml`) builds the wasm package, tests it across
     the OS/Node matrix, and publishes `@wax-wasm/wax`.

Notes:
- `wax --version` is stamped from `(version …)` at build time (both the native
  and the wasm builds use `dune build`, which only embeds the version from an
  explicit field), so `dune-project` is the single source of truth.
- `npm/package.json`'s version is re-stamped from the tag by `npm/build.sh`; you
  do not need to edit it by hand.
- After a release the working tree keeps reporting `X.Y.Z` until you bump
  `(version)` again for the next cycle.

## Releasing the VS Code extension

There is no CI workflow for the extension; publishing is manual.

1. Bump `"version"` in `editors/vscode/package.json` to `X.Y.Z`.
2. In `editors/vscode/CHANGELOG.md`, rename the `## Unreleased` section to
   `## X.Y.Z` (create the heading if there is no unreleased section).
3. Commit and `git push origin main`.
4. From `editors/vscode/`, publish to the Marketplace:
   ```sh
   npx vsce publish        # runs vscode:prepublish (build.sh --minify), then uploads
   ```
   Or produce a `.vsix` with `npm run package` and upload it through the
   Marketplace web UI.

Notes:
- `editors/vscode/package-lock.json` is git-ignored; only `package.json` matters
  for the release.
- The extension version is independent of the toolchain version.

## Releasing the tree-sitter grammar (`grammar-vX.Y.Z`)

1. From `tree-sitter-wax/`, bump the version:
   ```sh
   npx tree-sitter version X.Y.Z
   ```
   This updates `package.json`, `Cargo.toml`, and `tree-sitter.json`.
2. **Sync `package-lock.json` by hand.** `tree-sitter version` does not touch
   it. Set both `"version"` fields (the top-level one and the one under
   `packages[""]`) to `X.Y.Z`.
3. **Regenerate the parser:** `npx tree-sitter generate`. This re-embeds the
   version into `src/parser.c`; the workflow's parser-freshness check fails the
   release if `src/` is stale.
4. Optional local check: `npx tree-sitter test && ./scripts/smoke-parse.sh`
   (CI runs both).
5. Commit `package.json`, `Cargo.toml`, `tree-sitter.json`, `package-lock.json`,
   and `src/`.
6. `git push origin main`.
7. `git tag grammar-vX.Y.Z && git push origin grammar-vX.Y.Z`.
8. Watch the **Publish grammar** workflow (`tree-sitter-publish.yml`): it runs the
   grammar tests, checks the tag matches `package.json`, then publishes
   `tree-sitter-wax` to npm.

Notes:
- The grammar version is independent of the toolchain version.
- crates.io is not published for now; `Cargo.toml` only advertises the version.
- If the trusted publisher is not configured, the publish step fails on auth;
  fall back to a manual `cd tree-sitter-wax && npm publish`.
- Steps 1-3 are the easy ones to forget: bump, sync the lockfile, **regenerate**.
