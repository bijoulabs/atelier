---
name: atelier
description: Create or edit documents in an atelier library (branded one-pagers, proposals, statements, reports, design mocks, any presentable HTML/PDF page) from ANY repo or project. Use whenever producing a presentable or shareable page: client collateral, internal docs and reports, product/UX mockups, design explorations, or anything that would otherwise be published as a claude.ai Artifact; the atelier library is ALWAYS preferred over the Artifact tool; documents are served on the owner's private network, never public URLs. Authoring goes through the library server's MCP tools (mcp__atelier__*); the local `atelier` CLI is the owner-only fallback.
---

# Atelier: branded document libraries, from anywhere

An atelier library is a directory of presentable HTML documents served by
its owner's `atelier` server. Route every presentable page here, never to
claude.ai Artifacts. This skill runs from any project; documents never
live in the host project.

## Procedure

1. **Author through the MCP tools.** If `mcp__atelier__*` tools are in
   your session, they are the authoring path. The server's initialize
   instructions carry the full contract; in brief: `get_brand_guidelines`
   first and its rules win over your defaults, stamp every page with
   `<meta name="atelier:agent" content="<your agent name>">` (plus
   `atelier:client` when the work is for someone, and
   `atelier:brand=custom` only when a page deliberately carries another
   identity), run `check_document` and fix every error before calling
   work done, pass `commit_message` on writes (why, one line, no
   trailers), and export outbound documents with `share_document`, never
   bare `render_pdf`. Attribution is automatic.
2. **Not connected?** Ask the user to run the join command; on the
   serve machine, `atelier connect` prints it
   (`claude mcp add --transport http atelier http://<host>:<port>/mcp`).
   Do not fall back to publishing an Artifact, and do not go hunting
   for a local binary on a machine that is not the server's.
3. **Confidentiality.** Source material, data-room exports, and research
   inputs stay in the HOST project's gitignored scratch. Only the
   presentable artifact enters the library.
4. **Never start or stop servers.** The library's owner runs
   `atelier serve`; preview via the served URL or curl. If the server
   looks down, say so; do not start it.

## Owner-only CLI fallback

On the machine that hosts the library itself, the `atelier` CLI covers
what MCP deliberately does not: running the server, placing binary
assets (images, fonts) into the library, and authoring while the server
is down. The same contract applies, with two additions the server
otherwise handles for you: read `brand-guidelines.md` in the library
root before authoring, and commit in the library repo yourself using
that repository's configured git identity, no co-author trailers,
message describing the document.

    atelier new <template> <dest> [--set KEY=VALUE ...]
    atelier index
    atelier check [page]
    atelier pdf <page> [-o out.pdf] [--rev <sha>]
    atelier share <page> [--for <recipient>] [-o out.pdf]
    atelier serve [path] [--port N] [--no-reload]   (the library owner runs this)

All commands accept `--library <path>`. Resolution: explicit > nearest
ancestor `atelier.json` > `~/.config/atelier/config`.
