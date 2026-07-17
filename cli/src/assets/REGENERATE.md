# Regenerating pierre_diffs.js

`pierre_diffs.js` is a vendored, committed build of `@pierre/diffs`
(Apache-2.0, see `PIERRE_DIFFS_LICENSE.md`) bundled with Shiki's pure-JS
regex engine and only the grammars an atelier page diff can contain. It is
embedded into the binary via `@embedFile` and served at `/__assets/diffs.js`.
`zig build` never runs any of this; regeneration is a manual, deliberate act.

Vendored from `@pierre/diffs` 1.2.12 (Shiki 4.3.1), 2026-07-17.

## Recipe

In a scratch directory:

    npm init -y
    npm install @pierre/diffs esbuild
    cp <this dir>/pierre-entry.mjs <this dir>/shiki-shim.mjs .
    printf 'export default null;\n' > wasm-stub.mjs
    npx esbuild pierre-entry.mjs --bundle --minify --format=esm \
      "--alias:shiki/wasm=./wasm-stub.mjs" \
      "--alias:shiki/core=@shikijs/core" \
      --alias:shiki=./shiki-shim.mjs \
      --outfile=pierre_diffs.js

Then copy `pierre_diffs.js` and the package's `LICENSE.md` (as
`PIERRE_DIFFS_LICENSE.md`) back here, update the version line above, and
verify: build atelier, serve a library with git history, open a diff, and
confirm the split view renders with highlighting and the browser console
stays clean.

The shim (`shiki-shim.mjs`) is the size fence: it stands in for the full
`shiki` package so the bundle carries core + JS engine + html/css/js/json
grammars instead of every grammar shiki ships. If a future `@pierre/diffs`
imports new names from `shiki`, esbuild fails loudly with "No matching
export"; add the missing re-exports to the shim.
