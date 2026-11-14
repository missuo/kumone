#!/bin/bash
# Extracts the CHANGELOG.md section for a version.
# Usage: Scripts/release-notes.sh <version> [--html]
#   default: prints the section as markdown (fails if the section is missing/empty)
#   --html:  renders the section as simple HTML for the Sparkle appcast description
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:?usage: release-notes.sh <version> [--html]}"
FORMAT="${2:-md}"

SECTION="$(awk -v ver="$VERSION" '
  /^## / { on = ($2 == ver); next }
  on { print }
' "$ROOT/CHANGELOG.md")"

# Trim leading/trailing blank lines.
SECTION="$(printf '%s\n' "$SECTION" | awk 'NF {found=1} found' | awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last] !~ /[^[:space:]]/) last--; for (i=1;i<=last;i++) print lines[i]}')"

if [ -z "$SECTION" ]; then
  echo "ERROR: CHANGELOG.md has no section for version $VERSION (expected '## $VERSION - <date>')" >&2
  exit 1
fi

if [ "$FORMAT" != "--html" ]; then
  printf '%s\n' "$SECTION"
  exit 0
fi

printf '%s\n' "$SECTION" | awk '
  function closelist() { if (inlist) { print "</ul>"; inlist = 0 } }
  function escape(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  # Escape first, then render the inline markdown Sparkle would otherwise show
  # literally: **bold**, `code`. (Sparkle renders the description as HTML, not
  # markdown, so raw ** / ` markers leak into the update dialog.)
  function inline(s,   before, mid, after) {
    s = escape(s)
    while (match(s, /\*\*[^*]+\*\*/)) {
      before = substr(s, 1, RSTART - 1)
      mid    = substr(s, RSTART + 2, RLENGTH - 4)
      after  = substr(s, RSTART + RLENGTH)
      s = before "<strong>" mid "</strong>" after
    }
    while (match(s, /`[^`]+`/)) {
      before = substr(s, 1, RSTART - 1)
      mid    = substr(s, RSTART + 1, RLENGTH - 2)
      after  = substr(s, RSTART + RLENGTH)
      s = before "<code>" mid "</code>" after
    }
    return s
  }
  # A screenshot on a line of its own: ![alt](url)
  /^!\[.*\]\(.*\)[[:space:]]*$/ {
    closelist()
    line = $0; sub(/[[:space:]]*$/, "", line)
    cut = index(line, "](")
    printf "<p><img src=\"%s\" alt=\"%s\" style=\"max-width:100%%\"></p>\n", escape(substr(line, cut + 2, length(line) - cut - 2)), escape(substr(line, 3, cut - 3))
    next
  }
  /^### / { closelist(); printf "<h3>%s</h3>\n", inline(substr($0, 5)); next }
  /^---[[:space:]]*$/ { closelist(); print "<hr>"; next }
  /^- /   { if (!inlist) { print "<ul>"; inlist = 1 } printf "<li>%s</li>\n", inline(substr($0, 3)); next }
  /^[[:space:]]*$/ { next }
  { closelist(); printf "<p>%s</p>\n", inline($0) }
  END { closelist() }
'
