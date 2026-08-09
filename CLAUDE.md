# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## Build and test

    cd cli && zig build          # debug build to cli/zig-out/bin/atelier
    cd cli && zig build test     # run all unit tests
    ./install.sh                 # ReleaseSafe build to ~/.local/bin/atelier, links the skill

Tests live in the source files they test; the `test {}` block at the
bottom of `cli/src/main.zig` references every module so `zig build test`
sees the whole suite.

## What this is

One static Zig binary (`atelier`) plus the Claude Code skill that drives
it. Deliberately a two-repo design: this repo is generic software; all
content and branding live in a separate library repo (any directory with
`atelier.json`). Never hardcode brand identity here; built-in defaults
stay neutral and served pages make no external requests.

## Zig version drift

The toolchain is Zig 0.17.0-dev, newer than any stable docs: I/O sits
behind the `std.Io` capability, `main` takes `std.process.Init`, there
is no `std.net`. When older conventions do not compile, reconcile
mechanically against the installed std (`zig std` serves local docs),
preserve behavior exactly, and record the reconciliation in a `NOTE:`
doc comment. The source is full of examples of this habit.

## Architecture

`cli/src/main.zig` dispatches; one module per concern: `library.zig`
(resolution: explicit path > nearest ancestor manifest > config file;
also `write_mu` and `writeFileAtomic`), `theme.zig` (named themes,
presets, overlays, editor save validation), `template.zig` (fill plus
the scaffold core), `index.zig` (ledger generation; its CSS variable
names are pinned by test because the theme editor writes them),
`history.zig` (git wrappers: read for time travel, commitPaths for
server-side authorship), `pdf.zig` (headless Chromium), `check.zig`,
`share.zig` (the share core, used by CLI and server), `serve.zig`,
`mcp.zig` (the JSON-RPC endpoint and its tools), and `identity.zig`
(peer attribution, optional tailscale whois).

serve.zig is hand-rolled HTTP/1.1 over `std.Io.net`; do NOT switch it to
`std.http.Server` (its API churns across dev versions). The write
surface is `POST /__theme/save`, `POST /__theme/apply`, and `POST /mcp`
(remote authoring; stateless streamable HTTP, plain JSON responses, no
sessions, and no SSE on /mcp by design). Every library mutation the
server performs takes `library.write_mu`. One detached thread per
connection and per-connection `page_allocator` arenas are load-bearing
(SSE outlives requests); read the `handleConn` doc comment before
touching allocation there.

CLI commands and MCP tools share one implementation: the cores live in
their modules (`template.scaffold`, `share.sharePage`,
`pdf.materializeRev`, `check.checkPage`); `main.zig` and `mcp.zig` are
thin callers. Edit behavior in the core, never in one caller.

## Conventions

- `zig fmt` before every commit; tests written first, colocated.
- Assertions catch programmer errors; expected user-facing failures
  print a specific actionable message and exit 1.
- No em dashes anywhere: code comments, docs, commit messages.
- Commit messages say why; no Co-Authored-By or any other trailer.
- Zero build-time package dependencies. The one vendored asset is
  `cli/src/assets/pierre_diffs.js` (Apache-2.0); provenance and the
  regeneration recipe live in `cli/src/assets/REGENERATE.md`.
- The skill forbids agents from starting `atelier serve`; the library
  owner runs it. Keep that contract when editing the skill.
