#!/usr/bin/env bash
# Happy-path smoke test for a running SoterCare example.
# Run from examples/sotercare after `bal run`.
set -euo pipefail

api_url="${1:-http://localhost:9090}"
here="$(cd "$(dirname "$0")/.." && pwd)"

curl --fail --silent "$api_url/api/v1/health"
echo
curl --fail --silent \
  -H 'content-type: application/json' \
  --data @"$here/samples/normal-vitals.json" \
  "$api_url/api/v1/events"
echo
curl --fail --silent \
  -H 'content-type: application/json' \
  --data @"$here/samples/critical-fall.json" \
  "$api_url/api/v1/events"
echo
