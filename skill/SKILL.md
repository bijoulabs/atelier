---
name: atelier
description: Create or edit documents in an atelier library (branded one-pagers, proposals, statements, reports, any presentable HTML/PDF artifact) from ANY repo or project. Use whenever producing branded or client-facing collateral, or when asked for a one-pager, proposal, leave-behind, stamped PDF export, or a document library. Drives the `atelier` CLI (new/index/check/pdf/share/serve); content lives in the configured atelier library, not the current project.
---

# Atelier: branded document libraries, from anywhere

An atelier library is a directory of presentable HTML documents with an
`atelier.json` manifest, a `brand-guidelines.md`, and `templates/`. The
`atelier` CLI indexes, lints, serves, and exports it. This skill runs from any
project; documents never live in the host project.

## Procedure

1. **Resolve the library.** `--library <path>` on every command; otherwise the
   nearest ancestor with `atelier.json`, then `library=` in
   `~/.config/atelier/config`. A task can name a different library.
2. **Read `brand-guidelines.md` in the library root before authoring anything.**
   It is the canon for palette, type, components, layout, writing style, and
   the library's own operational policy (how documents may be shared, who runs
   the server). Its rules win over your defaults.
3. **Author in the library working tree.** HTML only for presentable documents;
   print collateral keeps a one-page discipline unless the guidelines say
   otherwise. Start from a master: `atelier new <template> <dest> --set
   KEY=VALUE ...` fills mechanical placeholders (including `{{BRAND_*}}` tokens
   from the manifest theme) and reports what remains; write the judgment
   content yourself, in the library's voice. Stamp every page you create with
   `<meta name="atelier:agent" content="<your agent name>">` and, when the work
   is for someone, `<meta name="atelier:client" content="<client>">` (double
   quotes, `name` before `content`): the index's provenance stamps and filter
   chips come from these. A page deliberately carrying another identity (a
   client's own brand) declares `<meta name="atelier:brand" content="custom">`
   to opt out of style warnings only.
4. **Check before committing.** Run `atelier check <page>` and fix every error
   (missing title or agent stamp, broken internal links, forbidden characters);
   treat palette and font warnings as brand-drift signals. `atelier index`
   refreshes the ledger; it is unnecessary while the library's server is
   running, which reindexes on change.
5. **Export deliberately.** For anything sent outside, prefer
   `atelier share <page> --for <client>` over bare `atelier pdf`: it stamps the
   artifact with provenance and records the send in `shares.log`.
   `atelier pdf <page> --rev <sha>` reproduces exactly what was sent before.
6. **Commit in the library repo** using that repository's configured git
   identity, no co-author trailers, message describing the document.
7. **Confidentiality.** Source material, data-room exports, and research inputs
   stay in the HOST project's gitignored scratch. Only the presentable artifact
   enters the library.
8. **Never start or stop servers.** The library's owner runs `atelier serve`;
   preview via the served URL or curl. If the server looks down, say so; do not
   start it.

## CLI quick reference

    atelier new <template> <dest> [--set KEY=VALUE ...]
    atelier index
    atelier check [page]
    atelier pdf <page> [-o out.pdf] [--rev <sha>]
    atelier share <page> [--for <recipient>] [-o out.pdf]
    atelier serve [path] [--port N] [--no-reload]   (the library owner runs this)

All commands accept `--library <path>`. Resolution: explicit > nearest ancestor
`atelier.json` > `~/.config/atelier/config`.
