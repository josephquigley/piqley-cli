#!/usr/bin/env bash
# Require CHANGELOG.md to be staged when source files change.
# Skips docs-only and chore commits (detected by staged file paths).

set -euo pipefail

staged=$(git diff --cached --name-only --diff-filter=ACMR)

# Nothing staged — nothing to check
[ -z "$staged" ] && exit 0

# If CHANGELOG.md is already staged, we're good
echo "$staged" | grep -q '^CHANGELOG.md$' && exit 0

# Check if any non-doc, non-config source files are staged
has_source=false
while IFS= read -r file; do
    case "$file" in
        docs/*|*.md|.pre-commit-config.yaml|.gitignore|.github/*|.claude/*|.superpowers/*|.agents/*) ;;
        *) has_source=true; break ;;
    esac
done <<< "$staged"

if $has_source; then
    echo "ERROR: Source files changed but CHANGELOG.md was not updated."
    echo "Add an entry under '## Unreleased' in CHANGELOG.md."
    echo ""
    echo "To skip this check (docs/chore only), use: git commit --no-verify"
    exit 1
fi
