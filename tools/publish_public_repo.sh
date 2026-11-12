#!/bin/bash
# Publishes the scrubbed history as a NEW public GitHub repo, so CI gets free
# macOS runners. The existing private repo stays private and untouched (its
# old commits and Actions logs mention client work).
#
#   tools/publish_public_repo.sh [owner/name] ASC_P8_FILE
#     owner/name   default MusaInc/musa-control
#     ASC_P8_FILE  the App Store Connect *Admin* API key (.p8) used for TestFlight
# It asks for the team id, issuer id and key id (the private repo's secrets
# hold the same values; GitHub never shows them, so you type them once).
set -euo pipefail
REPO="${1:-MusaInc/musa-control}"; P8="${2:-}"
cd "$(dirname "$0")/.."

# 1. Refuse to publish if any commit, message or file anywhere still names client work.
PATTERN="$(cat "$HOME/.config/musa-control/private-terms")"  # private; never in the repo
for b in main multi-user; do git rev-parse -q --verify "$b" >/dev/null || { echo "branch $b missing"; exit 1; }; done
HITS=$(git log main multi-user -p --format='%an %ae %cn %ce %B' | grep -ciE "$PATTERN" || true)
[ "$HITS" = "0" ] || { echo "Refusing: $HITS mention(s) of client work in history. Run tools/scrub_history.sh first."; exit 1; }
git grep -qiE "$PATTERN" main multi-user && { echo "Refusing: client names in current files."; exit 1; }
echo "history check: clean"
[ -n "$P8" ] && [ -f "$P8" ] || { echo "Give the path of the Admin .p8 key as the 2nd argument."; exit 1; }
read -rp "Apple team id: " TEAM; read -rp "ASC issuer id: " ISSUER; read -rp "ASC key id: " KEYID

# 2. Create the public repo and push only the two scrubbed branches (no tags, no other refs).
gh repo view "$REPO" >/dev/null 2>&1 || gh repo create "$REPO" --public --description "Musa Control: control the AI coding agents on your own computers from iPad and iPhone" --disable-wiki
git push "https://github.com/$REPO.git" main:main multi-user:multi-user

# 3. CI secrets and build numbering (TestFlight builds must keep counting up from the private repo's).
printf '%s' "$TEAM" | gh secret set APPLE_TEAM_ID -R "$REPO"
printf '%s' "$ISSUER" | gh secret set ASC_ISSUER_ID -R "$REPO"
printf '%s' "$KEYID" | gh secret set ASC_KEY_ID -R "$REPO"
gh secret set ASC_KEY_P8 -R "$REPO" < "$P8"
gh variable set BUILD_BASE -R "$REPO" --body 100
echo "Published https://github.com/$REPO. Next: gh workflow run ios.yml -R $REPO --ref multi-user -f testflight=false"
