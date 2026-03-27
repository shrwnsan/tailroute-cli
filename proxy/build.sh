#!/bin/bash
set -e

# Build script for tailroute-proxy
# Builds arm64 macOS binary

cd "$(dirname "$0")"

VERSION=${VERSION:-dev}
DATE=$(date -u +%Y-%m-%d)
OUTPUT="build/tailroute-proxy"

echo "Building tailroute-proxy ${VERSION}..."

go build -ldflags="-s -w -X main.version=${VERSION} -X main.buildDate=${DATE}" \
    -o "${OUTPUT}" .

echo "Built: ${OUTPUT}"
echo "Version: ${VERSION}"
echo "Date: ${DATE}"

# Make executable
chmod +x "${OUTPUT}"

echo "Done."
