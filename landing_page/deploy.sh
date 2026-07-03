#!/usr/bin/env bash
# Manual deploy of the landing page to roads.anishsheela.com.
# CI does this automatically on push (see .github/workflows/deploy-landing-page.yml);
# use this only for an out-of-band push from your machine.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/"
DEST="anish@roads.anishsheela.com:/var/www/roads.anishsheela.com/"

rsync -avz --delete \
  --chmod=D755,F644 \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='.claude' \
  --exclude='.DS_Store' \
  --exclude='deploy.sh' \
  "$SRC" "$DEST"
