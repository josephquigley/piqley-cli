#!/bin/bash
set -euo pipefail

# Creates a Homebrew bottle from the local tap.
# Usage: ./scripts/create-bottle.sh [version]
# Example: ./scripts/create-bottle.sh 1.0.0

VERSION="${1:?Usage: $0 <version>}"

echo "==> Syncing tap..."
cd /opt/homebrew/Library/Taps/quigs/homebrew-tools && git pull origin main
cd -

echo "==> Building bottle for v${VERSION}..."
brew install --build-bottle quigs/tools/quigsphoto-uploader

echo "==> Creating bottle..."
cd /tmp
brew bottle --json \
  --root-url="https://github.com/josephquigley/quigsphoto-uploader/releases/download/v${VERSION}" \
  quigs/tools/quigsphoto-uploader

echo ""
echo "==> Bottle created in /tmp:"
ls -la /tmp/quigsphoto-uploader--*.tar.gz
echo ""
echo "==> Bottle JSON (paste the bottle block into Formula/quigsphoto-uploader.rb):"
cat /tmp/quigsphoto-uploader--*.json
echo ""
echo "==> Next steps:"
echo "  1. Upload the .tar.gz to the GitHub release for v${VERSION}"
echo "  2. Update Formula/quigsphoto-uploader.rb with the bottle block from above"
echo "  3. Commit and push"
