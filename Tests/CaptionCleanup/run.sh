#!/usr/bin/env bash
# CaptionCleanup(字幕の重複・誤認識の掃除)の検査。Xcode が無くても swiftc だけで動く:
#   Tests/CaptionCleanup/run.sh
# GitHub Actions では .github/workflows/caption-tests.yml が Linux の Swift コンテナで実行する
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -parse-as-library -o "$OUT/caption-cleanup-tests" \
  "$ROOT/Sources/Engine/CaptionCleanup.swift" \
  "$ROOT/Sources/Model/CaptionIssues.swift" \
  "$ROOT/Tests/CaptionCleanup/Stubs.swift" \
  "$ROOT/Tests/CaptionCleanup/CaptionCleanupTests.swift"
"$OUT/caption-cleanup-tests"
