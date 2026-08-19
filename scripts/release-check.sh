#!/usr/bin/env bash
# Pre-publication gate. Run this from a clean checkout of the exact commit you
# intend to publish, and only run `bal push` if it exits zero.
#
# It deliberately does NOT push anything anywhere.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() { echo "BLOCKED: $*" >&2; exit 1; }

echo "== toolchain =="
bal version

echo "== metadata =="
grep -q '^repository = ' Ballerina.toml \
  || fail "Ballerina.toml has no 'repository' value. Add the real URL before publishing."
grep -q '^version = "0.1.0"' Ballerina.toml \
  || echo "note: version is not 0.1.0; confirm this is intended"

echo "== working tree =="
if git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || fail "uncommitted changes; publish the exact tested tree"
  echo "commit: $(git rev-parse --short HEAD)"
else
  fail "not a git repository; Central versions are immutable and need a matching tag"
fi

echo "== clean build from scratch =="
bal clean
bal test --code-coverage
mkdir -p ci-artifacts
cp -r target/report ci-artifacts/library-coverage 2>/dev/null || true
bal build
bal pack
bal doc

echo "== consumers against the freshly packed bala =="
bal push --repository=local
for example in examples/basic-webhook examples/generic-iot examples/sotercare; do
  ( cd "$root/$example" && bal clean && bal test && bal build )
done

echo
echo "release check passed. Artifact:"
ls -1 target/bala/
echo
echo "Remaining manual steps before 'bal push':"
echo "  1. confirm you own the org at https://central.ballerina.io/<org>"
echo "  2. bal login"
echo "  3. bal push        # IMMUTABLE - this version can never be replaced"
