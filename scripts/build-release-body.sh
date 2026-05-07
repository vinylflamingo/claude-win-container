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

  # Stable releases publish `:latest` aliases. Preview runs publish `:preview`
  # aliases instead -- both are rolling pointers to the most recent build in
  # their respective channels. The SHA-pinned rows above stay so testers can
  # reproduce a specific build.
  if [ "${PREVIEW_BANNER:-}" = "1" ]; then
    cat <<EOF
| \`${IMAGE_NAME}:preview\` | ltsc2019 | rolling -- overwritten on each preview push |
| \`${IMAGE_NAME}:preview-ltsc2019\` | ltsc2019 | rolling |
| \`${IMAGE_NAME}:preview-ltsc2022\` | ltsc2022 | rolling |
EOF
  else
    cat <<EOF
| \`${IMAGE_NAME}:latest\` | ltsc2019 | rolling |
| \`${IMAGE_NAME}:latest-ltsc2019\` | ltsc2019 | rolling |
| \`${IMAGE_NAME}:latest-ltsc2022\` | ltsc2022 | rolling |
EOF
  fi

  # Quickstart differs by channel:
  #   - Stable: standard `irm | iex` against the /latest/ redirect (default
  #     -Ref = 'latest' inside install.ps1, so no args needed).
  #   - Preview: must pass -Ref preview to install.ps1, which means using the
  #     scriptblock form -- `irm | iex` does NOT bind args from $args/$PSBoundParameters
  #     in the parent scope into the iex'd script's param() block. install.ps1
  #     records the channel in ~/.cwc/config.json so cwc defaults to :preview
  #     images afterwards (no need to set CWC_IMAGE per shell).
  if [ "${PREVIEW_BANNER:-}" = "1" ]; then
    cat <<EOF

## Quickstart

\`\`\`powershell
& ([scriptblock]::Create((irm https://github.com/vinylflamingo/claude-win-container/releases/download/preview/install.ps1))) -Ref preview
cd path\\to\\project
cwc
\`\`\`

After install, \`cwc\` defaults to the rolling \`:preview\` image. To pin this exact build instead:

\`\`\`powershell
\$env:CWC_IMAGE = '${IMAGE_NAME}:${VERSION}'
\`\`\`

To go back to the latest stable, re-run the standard install command (\`irm .../releases/latest/download/install.ps1 | iex\`); it rewrites the channel field.
EOF
  else
    cat <<EOF

## Quickstart

\`\`\`powershell
irm https://github.com/vinylflamingo/claude-win-container/releases/latest/download/install.ps1 | iex
cd path\\to\\project
cwc
\`\`\`

**Pin this version:**

\`\`\`powershell
\$env:CWC_IMAGE = '${IMAGE_NAME}:${VERSION}'
\`\`\`
EOF
  fi
} > release-body.md

echo "Wrote $(wc -l < release-body.md) lines to release-body.md"
