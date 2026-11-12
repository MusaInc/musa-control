#!/bin/bash
# Rewrites main and multi-user so no file or commit message names client work
# (private replacement list in ~/.config/musa-control/scrub_text.py). Local only; makes a bundle backup first.
set -euo pipefail
cd "$(dirname "$0")/.."
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash changes first."; exit 1; }
git bundle create "$HOME/.cache/musacontrol-backup-$(date +%Y%m%dT%H%M%S).bundle" --all
PY="$HOME/.config/musa-control/scrub_text.py"            # private replacement list
PATTERN="$(cat "$HOME/.config/musa-control/private-terms")"
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --tree-filter "git ls-files -z | xargs -0 grep -lIiE '$PATTERN' 2>/dev/null | tr '\n' '\0' | xargs -0 -r python3 -I '$PY'" \
  --msg-filter "python3 -I '$PY'" -- main multi-user
git for-each-ref --format='%(refname)' refs/original | xargs -r -n1 git update-ref -d
echo "Remaining mentions: $(git log main multi-user -p --format='%B' | grep -ciE "$PATTERN" || true)"
