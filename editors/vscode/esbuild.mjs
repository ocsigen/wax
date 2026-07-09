// Bundle the extension into one file per host: a Node bundle for the desktop
// extension host and a browser bundle for the web extension host. `vscode` is
// provided by the host, so it stays external. Run via build.sh, which first
// builds and copies the wasm runtime into dist/wax.

import * as esbuild from "esbuild";

const minify = process.argv.includes("--minify");

const shared = {
  bundle: true,
  external: ["vscode"],
  format: "cjs",
  sourcemap: true,
  minify,
  logLevel: "info",
};

await esbuild.build({
  ...shared,
  entryPoints: ["src/extension.node.ts"],
  outfile: "dist/extension.node.js",
  platform: "node",
  target: "node18",
});

await esbuild.build({
  ...shared,
  entryPoints: ["src/extension.web.ts"],
  outfile: "dist/extension.web.js",
  platform: "browser",
  target: "es2022",
});
