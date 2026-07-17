# atelier

A single-binary toolchain for branded HTML collateral libraries, plus the
global Claude Code skill that drives it. Content lives elsewhere (see the
library contract below); this repo is generic software with nothing
confidential in it.

## Commands

    atelier new <template> <dest> [--set KEY=VALUE ...]   scaffold from a master
    atelier index                                          regenerate index.html
    atelier pdf <page> [-o out.pdf]                        render via headless Chromium
    atelier check [page]                                   lint against the brand and structure
    atelier share <page> [--for X] [-o out.pdf]            stamped PDF export + share log
    atelier serve [path] [--port N] [--no-reload]          static server, hot reload, auto-index, time travel

## Library contract

A library is any directory with an `atelier.json`:

    { "name": "Acme Co", "tag": "Example · Tagline", "port": 8789 }

plus `brand-guidelines.md` and `templates/`. Resolution order: explicit path,
nearest ancestor with `atelier.json`, then `library=` in `~/.config/atelier/config`.

### Theming

The index page's branding comes from an optional `theme` object in
`atelier.json`; every field defaults to a neutral look with no external
requests. Colors are CSS color values, fonts are CSS font-family stacks,
`font_link` is a stylesheet URL (emitted as a `<link>` when set):

    "theme": {
      "paper": "#FFFCF8", "ink": "#1b1a17",
      "muted": "#57534a", "accent": "#9a3b32", "rule": "#e2c9b5",
      "display_font": "'Fraunces',Georgia,serif",
      "mono_font": "'JetBrains Mono',ui-monospace,monospace",
      "font_link": "https://fonts.googleapis.com/css2?family=..."
    }

The wordmark accents the first comma of `name` with the theme's accent
color (invisible under the neutral theme, whose accent equals the ink).

An optional `palette` array in the theme lists extra hex colors
`atelier check` accepts (the brand's extended palette). Theme values also
feed `atelier new` as `{{BRAND_*}}` placeholders (`BRAND_PAPER`,
`BRAND_INK`, `BRAND_MUTED`, `BRAND_ACCENT`, `BRAND_RULE`,
`BRAND_DISPLAY_FONT`, `BRAND_MONO_FONT`, `BRAND_FONT_LINK`), so masters
scaffold with the current brand.

### Checking

`atelier check [page]` lints one page or the whole library. Errors (exit
1): missing or blank title, missing `atelier:agent` stamp, em dashes,
broken internal references (serve's clean-URL rules applied). Warnings:
hex colors outside the theme palette, font families outside the theme
stacks. A page declaring `<meta name="atelier:brand" content="custom">`
is a deliberate sub-brand and skips the style warnings only.

Check rules are opinionated by default and configurable via an optional
`check` object in `atelier.json`: `{ "check": { "forbid_em_dash": false } }`
disables the em dash error.

### Time travel

When the library is a git repository, every page served by `atelier serve`
carries a history chip (top right, hidden in print) listing the commits
that touched that page. Picking one re-renders the page as of that commit
under a `/@<sha>/` URL prefix; because the prefix is part of the path,
every relative asset and link the page requests resolves from the same
commit, a faithful whole-tree snapshot. Snapshots are read straight from
git, never written to disk, and skip hot reload; the working tree stays
the default view. History stops at a page's last rename.

The same panel diffs any two versions of a page: each row carries a
from/to pick (the working tree included), and the diff view at
`/__diff/<page>?from=X&to=Y` renders side by side or stacked with syntax
highlighting, courtesy of a vendored [@pierre/diffs](https://diffs.com)
build (Apache-2.0) embedded in the binary and served at
`/__assets/diffs.js`. No external requests; see
`cli/src/assets/REGENERATE.md` for provenance and the update recipe.

### Page metadata

Pages may declare `<meta name="atelier:KEY" content="VALUE">` tags (double
quotes, `name` before `content`; keys `[a-z0-9_-]+`). All values are
searchable from the index. Two keys are first-class: `atelier:agent` (who
authored the page) and `atelier:client` (who it is for) render as stamps
on each ledger entry and become filter chips.

## Install

    ./install.sh [library-path]    builds to ~/.local/bin/atelier, links the
                                   skill into ~/.claude/skills/atelier; the
                                   optional path seeds ~/.config/atelier/config

## Build / test

    cd cli && zig build && zig build test
