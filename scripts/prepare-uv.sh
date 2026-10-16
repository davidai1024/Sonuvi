#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
uv_version="0.12.5"
uv_archive="uv-aarch64-apple-darwin.tar.gz"
uv_tmp="$(mktemp -d)"
trap 'rm -rf "$uv_tmp"' EXIT
curl --fail --location --retry 2 --proto '=https' --tlsv1.2 \
  "https://github.com/astral-sh/uv/releases/download/$uv_version/$uv_archive" \
  --output "$uv_tmp/uv.tar.gz"
tar -xzf "$uv_tmp/uv.tar.gz" -C "$uv_tmp"
mkdir -p Resources
cp "$uv_tmp/uv-aarch64-apple-darwin/uv" Resources/uv
chmod +x Resources/uv
Resources/uv --version
