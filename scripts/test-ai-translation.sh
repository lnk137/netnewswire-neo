#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/netnewswire-neo-tests.XXXXXX")
trap 'rm -r "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library Mac/AITranslation/AITranslationClient.swift Mac/AITranslation/AITranslationDocument.swift scripts/tests/AITranslationCoreTests.swift -o "$test_dir/tests"
"$test_dir/tests"
