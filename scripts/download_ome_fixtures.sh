#!/usr/bin/env bash
set -euo pipefail

# Download official public OME (Open Microscopy Environment) sample ND2 file for validation.
# Source: Open Microscopy Environment / downloads.openmicroscopy.org

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/fixtures"
mkdir -p "$FIXTURES_DIR"

OME_ND2_URL="https://downloads.openmicroscopy.org/images/ND2/maxime/BF007.nd2"
TARGET="$FIXTURES_DIR/BF007.nd2"

if [ ! -f "$TARGET" ]; then
    echo "Downloading public OME ND2 fixture (270 KB)..."
    curl -L -f -o "$TARGET" "$OME_ND2_URL"
    echo "Saved fixture to $TARGET"
else
    echo "Fixture already exists at $TARGET"
fi
