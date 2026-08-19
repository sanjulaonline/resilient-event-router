# Research notes and design decisions

Two dated layers. The first records the research behind the original SoterCare
application (15 August 2026). The second records what changed when the reusable
`sanjula/resilient_event_router` package was extracted from it (19 August 2026).

---

## Part 1 — the original SoterCare application (15 August 2026)

Research was checked against current official Ballerina documentation.

### Baseline

* Ballerina downloads lists Swan Lake `2201.13.5` as the current distribution.
* The generated lock file resolved `ballerina/http` `2.16.6`.
* The package declares `distribution = "2201.13.5"` so the intended compiler
  baseline is explicit.

Sources:

* https://ballerina.io/downloads/
* https://ballerina.io/learn/cli-commands/
* https://ballerina.io/learn/package-references/

### Typed payload binding

The official payload-binding example maps a JSON request body directly into a
record parameter. Failed binding returns `400 Bad Request`. The service
therefore uses a closed `SensorEvent` record at the resource boundary and tests
malformed JSON separately from application validation.

Source: https://ballerina.io/learn/by-example/http-service-data-binding/

### Typed status-code responses

The HTTP examples recommend records that include types such as `http:Conflict`
when a response needs a specific status and body. The service exposes named
response types for `202`, `400`, `409` and `503`. This made an important
compiler behaviour visible: structurally similar error records can be ambiguous
in a union, so each branch first constructs the intended named response type.

Source: https://ballerina.io/learn/by-example/http-send-different-status-codes-with-payload/

### Timeout, retry and circuit breaking

The outbound notifier client defined one policy in its client configuration:
one-second timeout; two retries starting at 0.05s with a 2.0 backoff factor
capped at 0.2s; a 10-second rolling window in 2-second buckets with a minimum
volume of 10, a 0.5 failure threshold, a 2-second reset time and failure
statuses `500`, `502`, `503`.

The retry example describes retries for network-level failures. The initial
project test incorrectly assumed a returned HTTP `500` would also be retried. It
was not. The corrected test asserted one downstream attempt for a `500`.

Sources:

* https://ballerina.io/learn/by-example/http-timeout/
* https://ballerina.io/learn/by-example/http-retry/
* https://ballerina.io/learn/by-example/http-circuit-breaker/

### Testing

Ballerina tests live under `tests/`, use `@test:Config`, and can exercise
services and clients. The package used HTTP-level tests rather than testing only
helper functions, so payload binding, status mapping, the mock dependency and
idempotency were covered together.

Sources:

* https://ballerina.io/learn/test-ballerina-code/write-tests/
* https://ballerina.io/learn/test-ballerina-code/test-services-and-clients/
* https://ballerina.io/learn/test-ballerina-code/structure-tests/

### Observability

The package set `observabilityIncluded = true` and emitted contextual logs.
Ballerina's observability documentation notes that services and clients are
observable, but runtime reporting still needs a configured backend. The project
does not claim that an external observability stack is running.

Sources:

* https://ballerina.io/learn/overview-of-ballerina-observability/
* https://ballerina.io/learn/observe-ballerina-programs/

### Safety boundary

All data is synthetic. The thresholds are deterministic examples designed to
exercise routing branches; they have not been clinically reviewed. The project
must not be represented as detecting, diagnosing or treating a medical
condition. This still holds for `examples/sotercare`.

---

## Part 2 — extracting the reusable package (19 August 2026)

### What was actually reusable

Reading the original six source files, the split was cleaner than expected. Only
`validation.bal` was genuinely domain logic. Everything else — the resilient
client, the in-memory processed-event map, the response mapping, the structured
logging — was infrastructure with SoterCare vocabulary attached to it. The
extraction was therefore mostly a renaming and inversion problem, not a rewrite.

The coupling that had to be broken:

* `SensorEvent` (device, value, unit, timestamp) was the only event shape the
  resilient client could send.
* The routing decision (`"caregiver-notifier"` vs `"event-log"`) was produced by
  the classifier and consumed by the service, with no seam between them.
* `state.bal` was module-level global state shared by the service and the mock
  notifier, so idempotency could not be replaced or scoped.
* `notifyCaregiver` returned a bare `error`, so callers could not tell a
  connection failure from a `500`.

### Repository layout

Ballerina compiles `.bal` files in the package root, `modules/*` and `tests/`. A
directory named `examples/` inside a package is ignored by the compiler and is
excluded from the `.bala`, which was verified by unzipping the packed artifact.
The library therefore sits at the repository root, and each example is a
separate package under `examples/` with its own `Ballerina.toml`.

The examples resolve the library through the Ballerina **local repository**:
`bal pack` followed by `bal push --repository=local`, plus a `[[dependency]]`
entry with `repository = "local"` in each consumer. This is what makes
`examples/basic-webhook` a real external-consumer test rather than a same-package
test in disguise.

Source: https://ballerina.io/learn/manage-dependencies/

### Isolation

`Router` must be usable as a module-level `final` variable inside an `isolated`
service, so `Router` itself has to be an `isolated class`. That constrains its
fields: a `final` field whose type is an `isolated object` needs no lock, but a
mutable `map<DeliveryTarget>` does, and initialising such a field inside `init`
requires an *isolated expression*, which a plain local variable is not.

The resolution was a small `TargetRegistry` isolated class that owns the map and
guards it with `lock`. `new TargetRegistry()` is an isolated expression, so
`Router.init` can assign it directly, and `DeliveryTarget` being an isolated
object means instances can cross the `lock` boundary legally. `Classifier` and
`RoutingRule` are function values, which are in Ballerina's `readonly` set, so
they can be plain `final` fields.

### Idempotency contract

The original code did `isProcessed` then, much later, `markProcessed`, with a
gap wide enough for two concurrent callers to both pass. The contract is now
reserve/release/contains, and `reserve` is specified as atomic — exactly one
concurrent caller may receive `true`. That is a single `lock` for the in-memory
store and maps directly onto Redis `SET NX` or a unique database key, which is
what keeps a durable implementation from becoming a rewrite.

Release-on-failure is now explicit rather than incidental: the original relied on
"we did not reach `markProcessed`", the library actively releases the
reservation on every delivery failure, on an unknown destination and when the
breaker refuses to send.

The atomicity claim was later measured rather than left as an argument from the
lock. Substituting a store that reproduces the original check-then-act shape —
read, 1 ms gap, write — makes 100 concurrent callers *all* win the same id. The
real store, holding one lock across both steps, yields exactly one. That
substitution is also what proves the 100 strands are genuinely parallel, so the
passing test is evidence and not an artefact of a serialising scheduler.

### Retry: what was measured this time

The original finding was preserved and then completed. The negative case (a
`500` is not retried by `TransportRetryConfig`) already had a test. The positive case had
never been measured — the project simply asserted that transport failures *are*
retried.

`tests/mock_destination.bal` now runs a `ballerina/tcp` listener that counts
connections, accepts each one and closes it without writing an HTTP response.
That is a transport failure that can be counted from the outside. With
`transportRetry.count: 2` the listener records three connection attempts, and
with `count: 0` it records one. Both halves of the claim are now evidence.

The consequence for the API is that the two behaviours are separate records:
`TransportRetryConfig` (transport, on by default, invisible in `RouteResult.attempts`)
and `StatusRetryConfig` (application level, off by default, counted, bounded by
both attempts and elapsed time, and documented as requiring an idempotent
destination).

Sources:

* https://ballerina.io/learn/by-example/http-retry/
* https://ballerina.io/learn/by-example/tcp-listener-client/

### Error model

`ballerina/http` uses `distinct error<Detail>` with a subtype hierarchy, and the
library follows the same shape: `RouterError` at the root, with `ConfigError`,
`InvalidEventError`, `DuplicateEventError`, `InvalidDestinationError`,
`IdempotencyStoreError` and a `DeliveryError` family of `TransportError`,
`CircuitOpenError` and `DownstreamError`.

The delivery client deliberately takes `http:Response|http:ClientError` rather
than a data-bound value. Binding a typed response would collapse the very
distinction the package exists to expose: an `http:ClientError` means no HTTP
response was produced, while a `500` is a response and is classified by status
code. Circuit-open is detected first, by type where `ballerina/http` provides
one and by the documented "Upstream service unavailable" message otherwise.

### Severity

The library exposes three severities (`INFO`, `WARNING`, `CRITICAL`) because
that is enough for transport-level decisions. SoterCare keeps its own four-level
`CareSeverity` and maps down. That mapping — `critical` to `CRITICAL`,
`high`/`medium` to `WARNING`, everything else to `INFO` — is the clearest single
illustration of the split: the domain keeps the vocabulary it needs and hands
the router only what the router uses.

Because `medium` and `high` both map to `WARNING` but route differently,
SoterCare cannot express its routing with severity alone. It puts its route
decision in `Event.metadata` and reads it back in the routing rule, which also
demonstrates why `metadata` exists.

### Logging

`log:printError` with an error value prints the full stack trace of that error.
For a library that is the wrong default: a burst of delivery failures produces a
wall of identical traces. The library logs `eventId`, `eventType`, `severity`,
`destination`, `attempts`, `statusCode`, a low-cardinality `failure` label and
the error `reason`, and never the payload or metadata. The caller receives the
typed error and can log whatever it wants.

### Deliberately not built

No durable store, no outbox, no queue, no scheduler, no rule DSL, no metrics
exporter, no non-HTTP transport, no async delivery. `0.1.0` covers routing an
event to an HTTP destination with known failure behaviour, and says plainly in
the README what it does not cover.
