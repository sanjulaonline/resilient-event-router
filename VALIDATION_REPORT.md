# Validation report

Validated on 19 August 2026 on Windows 11 (x86_64), using Git Bash and
PowerShell 5.1.

This run covers the repository after the SoterCare application was split into a
reusable library (`sanjula/resilient_event_router`) and three example packages
that consume it, and after the pre-publication API review that followed.

## Toolchain

```text
Ballerina 2201.13.5 (Swan Lake Update 13)
Language specification 2024R1
Update Tool 1.5.1
JetBrains Runtime 21.0.9 (OpenJDK 21, build 21.0.9+1-b1038.76)
ballerina/http 2.16.6
ballerina/log  2.17.0
ballerina/time 2.8.1
ballerina/tcp  1.13.8   (scope = "testOnly")
```

The Ballerina ZIP distribution was downloaded from the official endpoint. Its
local SHA-256 was:

```text
042cee12015aad6eb1acc9fb0462f1f81adbafdcfdfa02240cafb16de2b24efc
```

This is the same digest recorded in the previous validation run of this
repository, so the toolchain is unchanged from the version the original project
was verified against. It records the exact downloaded file; it is not presented
as a published vendor checksum.

The distribution's `dependencies/` directory ships empty, so a Java 21 runtime
had to be supplied. The machine's default `java` is Temurin 17, which Ballerina
`2201.13.5` does not accept; `JAVA_HOME` was pointed at the JetBrains Runtime
21.0.9 already present on the machine. No Ballerina distribution upgrade was
made — the version pinned in every `Ballerina.toml` is still `2201.13.5`.

## Commands executed

Library (repository root):

```bash
bal version
bal format
bal test --code-coverage
bal build
bal pack
bal push --repository=local
bal doc
```

Each example package:

```bash
bal format
bal test --code-coverage
bal build
bal run           # basic-webhook, generic-iot, sotercare
```

`scripts/build-all.sh` runs the same sequence end to end.

## Automated results

### Library — `sanjula/resilient_event_router`

```text
51 passing
0 failing
0 skipped
Line coverage: 98.40% (307 covered, 5 missed)
```

Per file:

| File | Coverage |
| --- | --- |
| `config.bal` | 100.00% |
| `errors.bal` | 100.00% |
| `event.bal` | 100.00% |
| `idempotency.bal` | 100.00% |
| `router.bal` | 98.46% |
| `delivery.bal` | 96.81% |

Five lines remain uncovered and none of them is reachable by a test worth
writing: two are record/class declaration lines, and the other three are the
`ConfigError` branch taken when `new http:Client` itself fails. Because
`validateConfig` has already rejected every malformed URL by that point, there
is no deterministic input that makes the client constructor fail.

### Examples

| Package | Tests | Result | Coverage |
| --- | --- | --- | --- |
| `example/basic_webhook` (consumer test) | 4 | 4 passing, 0 failing | 0.00% |
| `example/generic_iot` | 3 | 3 passing, 0 failing | 58.82% |
| `sotercare/alert_router` | 11 | 11 passing, 0 failing | 89.63% |

All three were rebuilt from clean (`bal clean` then `bal build`) against the
freshly packed `.bala`, so none of these results comes from a stale artifact.

`basic_webhook` reports 0% because its only source file is `main.bal`, which the
tests deliberately do not call: the tests exercise the *library's* public API
through a local receiver. The package's job is to prove the package can be
imported and used from the outside, not to cover its own `main`.

Totals across the repository: **69 tests, 69 passing, 0 failing, 0 skipped.**

Raw reports are copied into `evidence/`.

### Tests that pin down the retry semantics

* `testHttpFiveHundredIsNotRetriedByTransportRetry` — with
  `transportRetry.count: 3`, a destination returning HTTP `500` receives
  **exactly one** request.
* `testCircuitOpenIsDetectedWithTransportRetryEnabled` — with
  `transportRetry.count: 2` and the breaker open, the result is still a
  `CircuitOpenError` and **zero** further requests reach the destination. This
  pins down the client-chain ordering that the typed circuit-open check relies
  on.
* `testTransportFailureIsRetried` — with `transportRetry.count: 2`, a TCP
  listener that accepts the connection and closes it without an HTTP response
  records **three** connection attempts.
* `testTransportRetryCanBeDisabled` — `transportRetry.count: 0` against the same
  TCP listener records **one** connection attempt.
* `testStatusRetryRecoversFromRepeatedFiveZeroThree` — with the opt-in
  `statusRetry` policy, two `503` responses followed by a `202` yields
  `RouteResult.attempts == 3`.
* `testHttpFiveHundredIsNotRetried` (SoterCare example) — the original
  regression test, unchanged in intent, still passes end to end through the
  library.

This is the first run in this repository in which the transport-retry half of
the claim was measured rather than assumed. The earlier project only proved the
negative case (a `500` is not retried); the TCP mock now proves the positive
case as well.


### Concurrency — the idempotency guarantee, measured

`tests/concurrency_test.bal` runs 100 strands started with `start`:

| Test | Assertion | Result |
| --- | --- | --- |
| `testConcurrentReserveHasExactlyOneWinner` | 100 concurrent `reserve` on one id | 1 `true`, 99 `false`, `size() == 1` |
| `testConcurrentReservesOfDistinctIdsAllSucceed` | 100 concurrent `reserve` on distinct ids | 100 `true`, `size() == 100` (no lost writes) |
| `testConcurrentRouteDeliversTheSameEventOnce` | 100 concurrent `route` of one event id | 1 `RouteResult`, 99 `DuplicateEventError`, destination received **1** request |
| `testConcurrentRouteAgainstAFailingDestinationLeavesNoReservation` | 20 concurrent `route` against a `500` | 20 typed failures, 0 deliveries, no surviving reservation |

**The test was checked for detection power before being kept.** A temporary
`RacyStore` reproducing the original check-then-act shape — read under one lock,
a 1 ms gap, write under another — was substituted for
`InMemoryIdempotencyStore` and the contended test re-run:

```text
[fail] zzProbeRacyStoreIsDetected:
    expected: '1'
    actual  : '92'
```

92 of the 100 strands observed the id as absent before any of them wrote it.
That result does two things: it proves the strands genuinely run in parallel
rather than being serialised by the scheduler, and it proves the assertion can
fail. The real store, which holds one lock across both the check and the write,
yields exactly one winner.

The probe was run twice, with and without an `@strand {thread: "any"}` hint on
the `start` actions (100 winners with, 92 without). Since the annotation made no
material difference to detection power and the compiler warns that it will be
deprecated, the tests use a plain `start`. The probe itself was deleted; only
the tests against the real store are kept.

This closes the last gap flagged in the previous review: `reserve` atomicity is
now measured rather than argued from reading the lock.

## Build results

```text
Compiling source
	sanjula/resilient_event_router:0.1.0

Creating bala
	target\bala\sanjula-resilient_event_router-any-0.1.0.bala

Successfully pushed target\bala\sanjula-resilient_event_router-any-0.1.0.bala to 'local' repository.
```

The `.bala` contains only `bala.json`, `docs/README.md`,
the six library `.bal` files, `package.json` and `dependency-graph.json`. The
`tests/` and `examples/` directories are not shipped.

`package.json` inside the `.bala`:

```json
{
  "organization": "sanjula",
  "name": "resilient_event_router",
  "version": "0.1.0",
  "licenses": ["Apache-2.0"],
  "authors": ["Sanjula"],
  "keywords": ["event","router","webhook","resilience","retry","circuit-breaker","iot","integration"],
  "export": ["resilient_event_router"],
  "ballerina_version": "2201.13.5",
  "platform": "any",
  "graalvmCompatible": true
}
```

There is deliberately no `source_repository`. An earlier revision carried a
guessed GitHub URL; this working tree is not a git repository and has no remote,
so the field was removed rather than invented. `Ballerina.toml` carries a TODO
where it belongs.

Example executables:

```text
examples/basic-webhook/target/bin/basic_webhook.jar   ~45 MiB
examples/generic-iot/target/bin/generic_iot.jar       ~45 MiB
examples/sotercare/target/bin/alert_router.jar        ~46 MiB
```

`bal doc` completed with no undocumented-symbol warnings. Reading the generated
`api-docs.json`, every exported symbol carries a description, and every method
on `Router`, `IdempotencyStore` and `InMemoryIdempotencyStore` has documented
parameters and return values. `Classifier` and `RoutingRule` appear under
`functionTypes`, both documented. The module-level `summary` field is empty;
Central renders `docs/README.md` as the overview instead, so this is cosmetic.

## Live observations — SoterCare example

`bal run` in `examples/sotercare`, then HTTP calls against the running process:

| Call | Status |
| --- | --- |
| `GET /api/v1/health` | `200` |
| `POST /api/v1/events` normal vitals | `202`, `routedTo: event-log`, `notified: false` |
| `POST /api/v1/events` critical fall | `202`, `routedTo: caregiver-notifier`, `notified: true` |
| same critical fall again | `409 DUPLICATE_EVENT` |
| `fail-` prefixed event | `503 NOTIFIER_UNAVAILABLE` |
| same `fail-` event again | `503`, notifier attempt counter now `2` |
| vitals value `500.0` | `400 INVALID_EVENT` |
| `{broken` | `400` at the payload-binding boundary |

Sample bodies:

```json
{"eventId":"vitals-demo-001","status":"accepted","severity":"normal","routedTo":"event-log","notified":false,"correlationId":"vitals-demo-001"}
{"eventId":"fall-demo-001","status":"accepted","severity":"critical","routedTo":"caregiver-notifier","notified":true,"correlationId":"fall-demo-001"}
{"code":"DUPLICATE_EVENT","message":"eventId has already been processed","correlationId":"fall-demo-001"}
{"code":"NOTIFIER_UNAVAILABLE","message":"event was not marked as processed; retry with the same eventId","correlationId":"fail-fall-demo-001"}
```

The second `fail-` call reaching the notifier a second time is the observable
proof that a failed delivery releases the event id instead of consuming it.

`bash scripts/smoke-test.sh` passed against a freshly started process. Against a
process that had already accepted the sample events it exits non-zero on the
`409`, which is correct behaviour for a happy-path script.

## Live observations — the other two examples

Both programs were run against the SoterCare mock notifier used as a generic
receiver:

```text
basic-webhook: delivered order-123 to default (status 202, attempts 1)
generic-iot:   sensor-555 -> paging  severity CRITICAL
               sensor-556 -> default severity INFO
```


## Pre-publication API review (same day)

A second pass tightened the public surface and the two workflow scripts before
any Central publication.

| Change | Reason |
| --- | --- |
| `RetryConfig` renamed to `TransportRetryConfig` | The field was already `transportRetry`; the type name now matches, and `TransportRetryConfig` / `StatusRetryConfig` read as the pair they are |
| `DEFAULT_TIMEOUT`, `DEFAULT_RETRY_COUNT` un-exported | Neither is needed to configure the router; the effective values are documented on the fields that use them |
| `Router.destinationNames()` un-exported | A routing-rule author already knows the names they configured; it survives as a module-private helper for tests |
| `repository` removed from `Ballerina.toml` | It was a guess. No git remote exists to read the real value from |
| Circuit-open message match removed | Replaced by a pure `err is http:UpstreamServiceUnavailableError` check |
| CI: Java 21 pinned, `setup-ballerina` bumped to `v1.1.4`, coverage report staged before `bal build` | Three defects found by running the same sequence locally |

Exported symbols: **40 before, 37 after.**

### The circuit-open check

`ballerina/http` `2.16.6` raises the open-breaker error at
`resiliency_http_circuit_breaker.bal:460`:

```ballerina
return error UpstreamServiceUnavailableError(errorMessage);
```

and `http_client_endpoint.bal:initialize` wraps the retry client *inside* the
circuit-breaker client, so that error is never re-wrapped as
`AllRetryAttemptsFailed`. The type test is therefore sufficient and the
message-string fallback was deleted.
`testCircuitOpenIsDetectedWithTransportRetryEnabled` locks the ordering in.

### Tests added

Six, all covering behaviour that can regress rather than lines that were merely
uncovered:

* `testCircuitOpenIsDetectedWithTransportRetryEnabled`
* `testEveryValidationGuardRejectsItsOwnCase` — one assertion per guard in
  `validateConfig`
* `testDisabledStatusRetryWithNoCodesIsAccepted` — `count: 0` with no status
  codes is a valid "never retry a status", not a configuration error
* `testStoreOutageSurfacesFromIsRoutedAndForget`
* `testReleaseFailureDoesNotMaskTheDeliveryError` — a store that cannot release
  must not swallow the delivery error
* `testLoggingCanBeDisabled` — `enableLogging: false` had no coverage

Library coverage moved from 93.33% to 98.40% as a side effect. No test was
written purely to raise the number.

## Implementation corrections caused by real execution

1. **`retry` is a reserved word.** `RouterConfig.retry` did not parse. The field
   is now `RouterConfig.transportRetry`, which also reads better next to
   `statusRetry`.
2. **`source` is a reserved word.** The webhook example's metadata key was
   renamed to `origin`.
3. **`http:Request.getHeader` returns `string|http:HeaderNotFoundError`,** not
   an optional. The test mock now type-tests instead of using `?:`.
4. **A tuple literal has no `sort`.** `[a, b].sort()` failed; the expected value
   is now bound to a `string[]` first.
5. **The circuit-breaker recovery test was wrong about its own mock.** It
   assumed an event id had exhausted its forced failures when it had used only
   one of two. Rewritten to drive both failures through the same id, which also
   exercises release-on-failure.
6. **Error logging was too loud.** `log:printError` with the error value emitted
   a full stack trace per failed delivery. The library now logs a
   low-cardinality `failure` label and the error `reason`, and returns the typed
   error to the caller instead.
7. **`bal build`, `bal pack` and `bal doc` clear `target/report`.** The coverage
   report has to be captured immediately after `bal test --code-coverage`.
   `scripts/build-all.sh` and the CI workflow both stage it now; without that the
   CI coverage artifact would always have been empty.

## Not validated in this run

* Docker image build. The Docker CLI is installed (28.4.0) but the daemon was
  not running on either attempt, so `examples/sotercare/Dockerfile` is
  unverified. It has been rewritten for the new two-package build (pack and
  publish the library to the local repository, then build the example) and needs
  a run before it is trusted.
* GitHub Actions execution. `.github/workflows/ci.yml` has not been pushed or run
  remotely. What was checked locally: the YAML parses, the twelve steps are in a
  workable order, the shell in every `run:` block passes `bash -n`, the
  `ballerina-platform/setup-ballerina` tag `v1.1.4` exists, and the command
  sequence is the one actually executed on this machine. Whether the action
  provisions `2201.13.5` correctly on `ubuntu-latest` can only be confirmed by
  running it.
* Publication to Ballerina Central. `bal push` to Central was not run and no
  credentials were used.
* Sustained load. The concurrency tests use 100 strands in a single burst; there
  is no soak, throughput or chaos measurement.
* External metrics or tracing backend.
* Any real healthcare or personal data. All data in this repository is synthetic.
