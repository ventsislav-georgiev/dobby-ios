#!/usr/bin/env bash
# The pure rules in ApiSchemeHandler, checked without Xcode, a simulator or a test
# target: swiftc builds the handler plus the check into one binary and runs it.
# WebKit and Security are macOS frameworks too, so the iOS source compiles here
# unchanged — the rules under check are plain Foundation either way.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/api-scheme-check"
xcrun swiftc -o "$OUT" \
  Dobby/AppConfig.swift Dobby/Web/ApiSchemeHandler.swift Tests/ApiSchemeHandlerCheck.swift
"$OUT"

# #068: ServerAddresses' connect/read timeout-staging decision, same pattern.
OUT2="$(mktemp -d)/server-addresses-check"
xcrun swiftc -o "$OUT2" \
  Dobby/ServerAddresses.swift Dobby/AppConfig.swift Tests/ServerAddressesCheck.swift
"$OUT2"
