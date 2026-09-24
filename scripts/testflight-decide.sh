#!/usr/bin/env bash
# #183: whether this TestFlight run builds. Pure, so Tests/run-checks.sh runs it for every
# case; testflight.yml feeds it the event name and, on schedule only, the pair this run
# would build plus how many unexpired artifacts carry that pair's names. Prints
# GITHUB_OUTPUT lines on stdout, the reason on stderr.
#
#   push / workflow_dispatch -> always build (a dobby-ios change, or someone asked);
#                               no other argument is read, so no API call gates it
#   schedule                 -> build unless testflight-<ios>-<pwa> exists (that exact
#                               pair is on TestFlight) or testflight-failed-<ios>-<pwa>
#                               exists (it failed within the last day)
#
#   testflight-decide.sh <event> [<ios-sha> <pwa-sha> <built-records> <failed-markers>]
set -euo pipefail
event="${1:?usage: testflight-decide.sh <event> [<ios-sha> <pwa-sha> <built-records> <failed-markers>]}"

if [ "$event" != schedule ]; then
  echo "testflight-decide: build=true ($event always builds)" >&2
  echo "build=true"
  exit 0
fi

ios="${2:-}" pwa="${3:-}" built="${4:-}" failed="${5:-}"
sha_re='^[0-9a-f]{40}$'
count_re='^[0-9]+$'
for pair in "dobby-ios:$ios" "PWA main:$pwa"; do
  if ! [[ "${pair#*:}" =~ $sha_re ]]; then
    # Never echo the rejected value: on a broken lookup it is the private PWA commit's
    # JSON (message, author), and this line lands in a public log. Its length only.
    value="${pair#*:}"
    echo "::error::testflight-decide: ${pair%%:*} head is not a 40-hex commit sha (got ${#value} characters)" >&2
    exit 1
  fi
done
if ! [[ "$built" =~ $count_re && "$failed" =~ $count_re ]]; then
  echo "::error::testflight-decide: record counts are not numbers (got ${#built} and ${#failed} characters)" >&2
  exit 1
fi

if [ "$built" -gt 0 ]; then
  build=false reason="this dobby-ios and PWA pair is already on TestFlight"
elif [ "$failed" -gt 0 ]; then
  build=false reason="this pair failed within the last day; a new commit on either side, or workflow_dispatch, retries now"
else
  build=true reason="no TestFlight build of this dobby-ios and PWA pair yet"
fi

echo "testflight-decide: build=$build ($reason)" >&2
echo "build=$build"
echo "pwa_sha=$pwa"
