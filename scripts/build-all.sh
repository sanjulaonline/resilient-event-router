#!/usr/bin/env bash
# Builds and tests the library, publishes it to the Ballerina local repository,
# then builds and tests every example package against that published artifact.
#
# This is the same sequence CI runs, and it is what proves the package works
# from the outside rather than only from its own tests.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "== library: test =="
bal test --code-coverage

# bal build, bal pack and bal doc all clear target/report, so keep a copy of the
# coverage report before they run.
mkdir -p ci-artifacts
cp -r target/report ci-artifacts/library-coverage 2>/dev/null || true

echo "== library: build =="
bal build

echo "== library: pack =="
bal pack

echo "== library: api docs =="
bal doc

echo "== library: publish to the local repository =="
bal push --repository=local

for example in examples/basic-webhook examples/generic-iot examples/sotercare; do
  echo "== ${example}: test =="
  (cd "$root/$example" && bal test)
  echo "== ${example}: build =="
  (cd "$root/$example" && bal build)
done

echo "all packages built; coverage report in ci-artifacts/library-coverage"
