#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="$(mktemp -t roryorbit-test)"
trap 'rm -f "$TEST_BIN"' EXIT

shopt -s nullglob
LIB_SOURCES=()
for src in "$ROOT"/Sources/*.swift; do
  if [[ "$(basename "$src")" == "main.swift" ]]; then
    continue
  fi
  LIB_SOURCES+=("$src")
done

TEST_SOURCES=("$ROOT"/Tests/*.swift)
shopt -u nullglob

if [[ ${#TEST_SOURCES[@]} -eq 0 ]]; then
  echo "Error: no test files found under $ROOT/Tests" >&2
  exit 1
fi

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Security \
  -framework CryptoKit \
  -framework Combine \
  -lsqlite3 \
  "${LIB_SOURCES[@]}" \
  "${TEST_SOURCES[@]}" \
  -o "$TEST_BIN"

"$TEST_BIN"
