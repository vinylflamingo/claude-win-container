#!/usr/bin/env bash
# Build a GitHub-release body markdown for a given version, combining the
# matching CHANGELOG.md section with a generated image table + quickstart.
# Writes to release-body.md in the current directory.
#
# Used by the release job in .github/workflows/build-and-release.yml.
# Can be run locally to preview what a release will look like:
#
#   IMAGE_NAME=fcostoya/claude-win-container ./scripts/build-release-body.sh 1.2.3
#
# Why this is a separate script (and not inline YAML):
#   The bash heredoc that emits the body needs to inject CHANGELOG content
#   verbatim alongside template variables (IMAGE_NAME, VERSION). An unquoted
#   heredoc would re-interpret '$', '`', '\' in the CHANGELOG content, which
#   our actual changelog does contain (code spans with backticks, $PROFILE
#   references, ${KEY} mentions). Splitting it into "verbatim block via
#   printf" + "templated block via heredoc" handles both correctly.

set -euo pipefail

VERSION="${1:?usage: $0 <version-without-v> [path/to/CHANGELOG.md]}"
CHANGELOG_PATH="${2:-CHANGELOG.md}"
: "${IMAGE_NAME:?env IMAGE_NAME required (e.g. fcostoya/claude-win-container)}"

if [ ! -f "$CHANGELOG_PATH" ]; then
  echo "ERROR: $CHANGELOG_PATH not found" >&2
  exit 1
fi

# Extract the `## [VERSION]` section. Stops at the next `## [` heading.
CHANGELOG_BODY=$(awk -v v="$VERSION" '
  /^## \[/ {
    if (found) exit
    if ($0 ~ "^## \\[" v "\\]") { found = 1; next }
  }
  found { print }
' "$CHANGELOG_PATH")

# Strip leading blank lines (sed) and trailing blank lines (awk reverse trick).
CHANGELOG_BODY=$(echo "$CHANGELOG_BODY" | sed -e '/./,$!d')
# Drop trailing blanks: read all into a buffer, walk backward to find the last
# non-blank line, print up to that point.
CHANGELOG_BODY=$(echo "$CHANGELOG_BODY" | awk 'NF{n=NR} {a[NR]=$0} END{for(i=1;i<=n;i++) print a[i]}')

if [ -z "$CHANGELOG_BODY" ]; then
  CHANGELOG_BODY="_No CHANGELOG entry for this version yet — see [CHANGELOG.md](./CHANGELOG.md)._"
fi

# Optional preview banner. Set PREVIEW_BANNER=1 in the env to prepend a
# "this is a pre-release" notice to the body. Used by preview/* branches.
PREVIEW_PREFIX=""
if [ "${PREVIEW_BANNER:-}" = "1" ]; then
  PREVIEW_PREFIX="> ⚠ **Pre-release.** This is a \`preview/*\` build for end-to-end validation of the publish pipeline. The \`latest\` Docker tags are NOT updated — pull this version explicitly with the exact tag below. Do not depend on this image; it may be replaced or deleted at any time."
fi

# Build the release body. The CHANGELOG section is written verbatim via
# printf '%s\n' (no shell re-interpretation), then the templated trailer is
# appended via a heredoc where backticks/dollars need explicit escaping.
{
  if [ -n "$PREVIEW_PREFIX" ]; then
    printf '%s\n\n' "$PREVIEW_PREFIX"
  fi
  printf '%s\n' "$CHANGELOG_BODY"
  cat <<EOF

---

## Docker images

| Tag | Base | Notes |
| --- | --- | --- |
| \`${IMAGE_NAME}:${VERSION}\` | ltsc2019 | default — max host compatibility |
| \`${IMAGE_NAME}:${VERSION}-ltsc2019\` | ltsc2019 | explicit |
| \`${IMAGE_NAME}:${VERSION}-ltsc2022\` | ltsc2022 | explicit |
EOF

  # Only stable releases publish `latest` aliases. Preview/* runs build the
  # version-tagged images but skip `latest` to avoid claiming stable status.
  if [ "${PREVIEW_BANNER:-}" != "1" ]; then
    cat <<EOF
| \`${IMAGE_NAME}:latest\` | ltsc2019 | rolling |
| \`${IMAGE_NAME}:latest-ltsc2019\` | ltsc2019 | rolling |
| \`${IMAGE_NAME}:latest-ltsc2022\` | ltsc2022 | rolling |
EOF
  fi

  cat <<EOF

## Quickstart

\`\`\`powershell
irm https://raw.githubusercontent.com/vinylflamingo/claude-win-container/main/install.ps1 | iex
cd path\\to\\project
cwc
\`\`\`

**Pin this version:**

\`\`\`powershell
\$env:CWC_IMAGE = '${IMAGE_NAME}:${VERSION}'
\`\`\`
EOF
} > release-body.md

echo "Wrote $(wc -l < release-body.md) lines to release-body.md"
