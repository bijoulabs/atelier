#!/bin/sh -e
# Rebuilds the README screenshots (docs/*.png) from the demo library in
# this directory. The library ships without git history, since a repo
# cannot nest a repo; this script recreates the two-draft history in a
# temp dir so the time-travel and diff shots have something to show.
# Needs atelier on PATH, git, chromium, and imagemagick.

here="$(cd "$(dirname "$0")" && pwd)"
docs="$(dirname "$here")"
work="$(mktemp -d)"
server=""
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

cp -r "$here/library" "$work/lib"
cd "$work/lib"
git init -q
git config user.email demo@example.invalid
git config user.name Demo
cp "$here/northwind-rebrand.draft-one.html" advisory/northwind-rebrand.html
git add -A
git commit -qm "first drafts of the northwind proposal and july notes"
cp "$here/library/advisory/northwind-rebrand.html" advisory/northwind-rebrand.html
git add -A
git commit -qm "second draft of northwind, tighter scope and a systems pass"

atelier index --library "$work/lib" >/dev/null
atelier serve "$work/lib" --port 8977 --no-reload &
server=$!
sleep 1

from="$(git log --format=%h | tail -1)"
to="$(git log --format=%h | head -1)"
shot() {
    chromium --headless=new --disable-gpu --force-device-scale-factor=2 \
        --window-size=1360,850 --virtual-time-budget=7000 --hide-scrollbars \
        --screenshot="$2" "$1" 2>/dev/null
}
shot "http://127.0.0.1:8977/" "$docs/ledger.png"
shot "http://127.0.0.1:8977/__theme" "$docs/theme-editor.png"
shot "http://127.0.0.1:8977/__diff/advisory/northwind-rebrand?from=$from&to=$to" "$docs/diff.png"

magick "$docs/ledger.png" -crop 2720x1560+0+0 +repage "$docs/ledger.png"
magick "$docs/diff.png" -crop 2720x1060+0+0 +repage "$docs/diff.png"

echo "wrote $docs/ledger.png, theme-editor.png, diff.png"
