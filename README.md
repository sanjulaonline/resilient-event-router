# Resilient Event Router for Ballerina

A Ballerina library for routing application events to HTTP destinations with
configurable timeout, retry, idempotency and circuit breaking.

```ballerina
import ballerina/io;
import sanjulaonline/resilient_event_router as router;

public function main() returns error? {
    router:Router eventRouter = check new ({
        destinationUrl: "https://example.com/webhook"
    });

    router:RouteResult result = check eventRouter.route({
        id: "order-123",
        eventType: "order.created",
        payload: {orderId: "123"}
    });

    io:println(result);
}
```

The library decides *how* to deliver an event. It never decides what an event
means: severity, validation and thresholds stay in your application.

Requires Ballerina Swan Lake `2201.13.5`. Depends only on `ballerina/http`,
`ballerina/log` and `ballerina/time`.

---

## Contents

1. [What it is](#what-it-is)
2. [Install](#install)
3. [Quick start](#quick-start)
4. [Event model](#event-model)
5. [Routing](#routing)
6. [Destinations](#destinations)
7. [Transport retries](#transport-retries)
8. [HTTP status retries](#http-status-retries)
9. [Circuit breaker](#circuit-breaker)
10. [Idempotency](#idempotency)
11. [Error handling](#error-handling)
12. [Logging](#logging)
13. [Public API](#public-api)
14. [Examples](#examples)
15. [SoterCare reference example](#sotercare-reference-example)
16. [Limitations](#limitations)
17. [Development and testing](#development-and-testing)
18. [Versioning](#versioning)
19. [License](#license)

---

## What it is

For each event handed to a `Router`:

1. the event id is reserved in an idempotency store, and a duplicate is rejected;
2. a severity is resolved — the one you passed, or one from your classifier;
3. a destination is chosen by your routing rule, or delivery is suppressed;
4. a JSON envelope is POSTed through an HTTP client with a timeout, transport
   retries with backoff, and a circuit breaker;
5. a typed `RouteResult` comes back, or a typed error and the event id is released.

The envelope on the wire:

```json
{
  "id": "order-123",
  "eventType": "order.created",
  "severity": "INFO",
  "metadata": {},
  "payload": { "orderId": "123" }
}
```

Sent with the headers `x-event-id`, `x-event-type` and `x-event-severity`, plus
any headers you configure.

Use it for webhook delivery, IoT and telemetry events, or notification and order
events — anywhere you would otherwise re-implement "POST this, retry the
network, do not send the same thing twice".

Do not use it for durable delivery across process restarts, exactly-once
semantics, fan-out to many subscribers, or non-HTTP transports. See
[Limitations](#limitations).

## Install

Once the package is on Ballerina Central, import it and build:

```ballerina
import sanjulaonline/resilient_event_router as router;
```

```bash
bal build
```

To use it from a clone of this repository, publish it to the Ballerina local
repository:

```bash
bal pack
bal push --repository=local
```

then declare it in the consuming package's `Ballerina.toml`:

```toml
[[dependency]]
org = "sanjulaonline"
name = "resilient_event_router"
version = "0.1.0"
repository = "local"
```

## Quick start

The example at the top of this page is the whole basic path:

```text
import  ->  new Router  ->  build an Event  ->  route()  ->  handle the result
```

`destinationUrl` is the only required setting. Everything else has a default: a
one-second timeout, two transport retries, a circuit breaker, an in-memory
idempotency store, `INFO` severity, and every event going to that one
destination.

Create one `Router` per set of destinations and keep it for the life of the
process. `Router` is an `isolated` object, so it works as a module-level `final`
variable inside an `isolated` service:

```ballerina
final router:Router eventRouter = check new ({destinationUrl: webhookUrl});

service /orders on new http:Listener(8080) {
    isolated resource function post events(OrderEvent event) returns http:Accepted|http:Conflict {
        router:RouteResult|router:RouterError result = eventRouter.route({
            id: event.id,
            eventType: "order.created",
            payload: event.toJson()
        });
        if result is router:DuplicateEventError {
            return <http:Conflict>{body: {code: "DUPLICATE"}};
        }
        return <http:Accepted>{body: {status: "accepted"}};
    }
}
```

## Event model

```ballerina
public type Event record {|
    string id;                    // idempotency key, required
    string eventType;             // free-form name, e.g. "order.created"
    json payload = ();            // sent to the destination, never logged
    map<string> metadata = {};    // routing context, never logged
|};
```

`id` must be stable across retries of the same logical event and unique across
distinct events; an empty `id` is an `InvalidEventError`.

`metadata` is for correlation ids, tenant ids, source names — small,
non-sensitive values a routing rule may want to read. Both `payload` and
`metadata` are forwarded in the envelope, and neither is written to a log.

`Severity` is `INFO`, `WARNING` or `CRITICAL`. It is passed to `route` or
produced by a classifier, and is echoed back in the result.

```ballerina
public type RouteResult record {|
    string eventId;
    string eventType;
    Severity severity;
    string? destination;   // () when the routing rule suppressed delivery
    boolean delivered;
    int attempts;
    int? statusCode;
|};
```

## Routing

Two optional functions, both plain Ballerina. There is no rule DSL; if you need
one, build it in your application and call it from the routing rule.

```ballerina
isolated function classifyEvent(router:Event event) returns router:Severity =>
    event.eventType.endsWith(".failed") ? router:CRITICAL : router:INFO;

isolated function pickDestination(router:Event event, router:Severity severity) returns string? {
    if severity == router:CRITICAL {
        return "paging";                  // a named destination
    }
    if event.eventType.startsWith("debug.") {
        return ();                        // record it, do not deliver it
    }
    return router:DEFAULT_DESTINATION;
}

router:Router eventRouter = check new ({
    destinationUrl: telemetryUrl,
    destinations: {paging: {url: pagerUrl}},
    classifier: classifyEvent,
    routingRule: pickDestination
});
```

* A severity passed to `route` overrides the classifier.
* Without a classifier, every event is `INFO`.
* Without a routing rule, every event goes to `DEFAULT_DESTINATION`.
* Returning `()` suppresses delivery. The event id is still reserved, and the
  result is `{delivered: false, destination: (), attempts: 0}`.
* Returning an unconfigured name is an `InvalidDestinationError`, and the event
  id is released.

## Destinations

`destinationUrl` becomes the destination named `DEFAULT_DESTINATION`
(`"default"`). Additional destinations are declared by name:

```ballerina
destinations: {
    paging: {url: "https://pager.example.com/alerts", headers: {"x-team": "sre"}}
},
headers: {"x-api-key": apiKey}
```

`RouterConfig.headers` apply to every destination; `DestinationConfig.headers`
are merged on top and win on conflict.

Each destination owns its own HTTP client, so **circuit-breaker state is per
destination** — a failing pager does not stop telemetry. A URL may include a
path and query string; both are preserved.

`init` returns a `ConfigError` for an empty or non-`http(s)` URL, a destination
named `default`, a non-positive timeout, or an out-of-range retry or breaker
value. It never panics.

## Transport retries

**Used when no valid HTTP response is obtained because of a network or transport
failure.** Applied by `ballerina/http`. Enabled by default.

```ballerina
transportRetry: {count: 2, interval: 0.05, backOffFactor: 2.0, maxWaitInterval: 0.2}
```

This covers connection refused, DNS failure, connection reset and idle timeout.
Those failures surface as a `TransportError`. Transport retries all happen inside
one application-level attempt, so they are invisible in `RouteResult.attempts`.
Set `count: 0` to disable.

**It does not retry HTTP error responses.** A `500` is a completed HTTP
exchange: the connection worked, the request arrived, the server answered. The
retry client exists for the case where no answer was produced at all.

The project this library was extracted from assumed otherwise. Both halves of
the behaviour are now pinned by tests:

```ballerina
// tests/retry_test.bal
// transportRetry.count: 3 against a destination returning 500
test:assertEquals(requestCount("fail500"), 1);   // one request, no retry

// transportRetry.count: 2 against a TCP listener that accepts and closes
test:assertEquals(requestCount("tcp"), 3);       // initial attempt plus two retries
```

| Situation | Error | Retried by `transportRetry` |
| --- | --- | --- |
| Connection refused, DNS failure, reset, timeout | `TransportError` | yes |
| Breaker open, request never sent | `CircuitOpenError` | no |
| Any non-2xx HTTP response | `DownstreamError` | no |

## HTTP status retries

**Optional application-level retry for selected HTTP response status codes.**
Disabled by default, and deliberately a separate setting from `transportRetry` —
the two are not interchangeable.

Retrying a status code means the destination already received and processed the
request, so **the destination must be idempotent for the retried event id**.
That is why this is opt-in.

```ballerina
statusRetry: {
    statusCodes: [502, 503, 504],   // do not include 4xx
    count: 2,
    interval: 0.2,
    backOffFactor: 2.0,
    maxInterval: 2,
    maxElapsedTime: 5               // ceiling for the whole delivery
}
```

Both bounds are enforced; whichever is reached first ends the delivery with a
`DownstreamError`. These attempts *are* counted in `RouteResult.attempts`.

| | `transportRetry` | `statusRetry` |
| --- | --- | --- |
| Trigger | no HTTP response | a listed status code |
| Default | on, `count: 2` | off |
| Applied by | `ballerina/http` | this library |
| Counted in `attempts` | no | yes |
| Time budget | per-retry interval only | also `maxElapsedTime` |
| Safe by default | yes | only if the destination is idempotent |

## Circuit breaker

Enabled by default, per destination:

```ballerina
circuitBreaker: {
    timeWindow: 10,
    bucketSize: 2,
    requestVolumeThreshold: 10,
    failureThreshold: 0.5,
    resetTime: 2,
    statusCodes: [500, 502, 503, 504]
}
```

While the breaker is open, `route` returns a `CircuitOpenError` without sending a
request, and the event id is released. After `resetTime` a trial request is
allowed; success closes the breaker.

`statusCodes` controls what counts as a failure *for the breaker* and is
independent of retrying — a `500` can trip the breaker while never being
retried. Set `circuitBreaker: ()` to disable.

## Idempotency

`route` reserves `Event.id` **before** classifying or delivering:

```text
reserve(id) -> false                     -> DuplicateEventError, nothing sent
reserve(id) -> true, delivery succeeds   -> id stays reserved
reserve(id) -> true, delivery fails      -> id is released, typed error returned
```

The id is released on every delivery failure, on an unknown destination, and when
the breaker refuses to send. **A failed delivery never permanently consumes an
event id**, so the caller can retry with the same id.

The store is pluggable:

```ballerina
public type IdempotencyStore isolated object {
    public isolated function reserve(string eventId) returns boolean|error;
    public isolated function release(string eventId) returns error?;
    public isolated function contains(string eventId) returns boolean|error;
};
```

`reserve` **must be atomic**: for a given id, exactly one concurrent caller may
receive `true`. That requirement is what lets a durable store drop in later —
Redis `SET NX`, or a unique database key — without changing the router.

The bundled store is tested under contention, not just argued from its lock:
100 concurrent `reserve` calls on one id yield exactly one `true`, and 100
concurrent `route` calls with the same event id produce one delivery and 99
`DuplicateEventError`s, with the destination receiving exactly one request.

`InMemoryIdempotencyStore` is the default and it is deliberately simple:

* **process-local** — not shared between replicas, so two instances of the same
  service will each accept the same event id once;
* **not durable** — every reservation is lost on restart;
* **unbounded** — there is no eviction or TTL; the map grows for the life of the
  process. `size()` reports the count and `clear()` empties it.

No Redis or database implementation ships in this release.

`Router.isRouted(id)` and `Router.forget(id)` read and clear a single id through
whichever store is configured.

## Error handling

Every error is a subtype of `RouterError` and carries an `ErrorDetail` with the
optional fields `eventId`, `destination`, `statusCode` and `attempts`.

```ballerina
router:RouteResult|router:RouterError result = eventRouter.route(event);

if result is router:DuplicateEventError {
    // expected outcome; usually HTTP 409
} else if result is router:CircuitOpenError {
    // the destination is being shielded; back off
} else if result is router:DownstreamError {
    int status = result.detail()?.statusCode ?: 0;
} else if result is router:TransportError {
    // no response at all; already retried per transportRetry
} else if result is router:RouterError {
    // ConfigError, InvalidEventError, InvalidDestinationError, IdempotencyStoreError
} else {
    // RouteResult
}
```

`DeliveryError` is the parent of `TransportError`, `CircuitOpenError` and
`DownstreamError`, so `result is router:DeliveryError` catches "could not
deliver" in one branch. You never have to parse an error message to identify a
common outcome.

## Logging

With `enableLogging: true` (the default) the library emits one `info` line per
routed event and one `error` line per failed delivery, through `ballerina/log`.

Logged keys: `eventId`, `eventType`, `severity`, `destination`, `delivered`,
`attempts`, `statusCode`, and on failures a low-cardinality `failure` label
(`transport`, `circuit-open`, `downstream-status`) plus the error `reason`.

Not logged: `payload`, `metadata`, request headers, response bodies. The error
value itself is not logged either, so a burst of failures does not produce a
stack trace per event — the typed error is returned to you instead. Set
`enableLogging: false` to silence the library.

## Public API

| Symbol | Purpose |
| --- | --- |
| `Router` | `init(RouterConfig)`, `route(Event, Severity?)`, `isRouted(string)`, `forget(string)` |
| `RouterConfig` | Everything a router needs; only `destinationUrl` is required |
| `Event` | `{id, eventType, payload, metadata}` |
| `Severity` | `INFO`, `WARNING`, `CRITICAL` |
| `RouteResult` | Outcome of a successful `route` call |
| `RouterError` | Base error type, with `ErrorDetail` |
| `ConfigError` | Unusable configuration |
| `InvalidEventError` | Empty `Event.id` |
| `DuplicateEventError` | The id was already reserved |
| `InvalidDestinationError` | The routing rule named an unconfigured destination |
| `DeliveryError` | Parent of the three delivery failures |
| `TransportError` | No HTTP response was produced |
| `CircuitOpenError` | The breaker refused to send |
| `DownstreamError` | The destination returned a non-2xx status |
| `IdempotencyStoreError` | A custom store failed |
| `Classifier` | `isolated function (Event) returns Severity` |
| `RoutingRule` | `isolated function (Event, Severity) returns string?` |
| `DestinationConfig` | `{url, headers}` |
| `TransportRetryConfig` | Transport-level retry policy |
| `StatusRetryConfig` | Application-level status-code retry policy |
| `CircuitBreakerConfig` | Breaker policy |
| `IdempotencyStore` | `reserve` / `release` / `contains` |
| `InMemoryIdempotencyStore` | Default store, plus `size` and `clear` |
| `DEFAULT_DESTINATION` | `"default"` — the name of the `destinationUrl` destination |

Anything not listed here is an implementation detail and may change without a
major version bump.

## Examples

Each example is its own Ballerina package and depends on the library the way any
external application would.

| Example | What it shows |
| --- | --- |
| [examples/basic-webhook](examples/basic-webhook) | Minimum usage; also the consumer test for the public API |
| [examples/generic-iot](examples/generic-iot) | Classifier plus routing rule across two destinations |
| [examples/sotercare](examples/sotercare) | A full service that keeps its domain logic and delegates delivery |

## SoterCare reference example

[examples/sotercare](examples/sotercare) is the project this library was
extracted from: a synthetic sensor-event API with validation, four-level
classification, an HTTP contract, and a deliberately unreliable mock notifier.

```text
sensor payload  ->  SoterCare validation  ->  SoterCare classification
                                                        |
                                                        v
                                            resilient_event_router
                                                        |
                                                        v
                                                    notifier
```

It is a worked example of the split: SoterCare keeps a four-level `CareSeverity`
and maps it down to the library's three, and carries its own routing decision in
`Event.metadata`.

It is an engineering prototype on synthetic data. It is not a medical device or
a clinical decision system.

## Limitations

Version `0.1.0` does not provide:

* durable idempotency — the bundled store is process-local, lost on restart, not
  shared between replicas, and never evicted;
* distributed locking, a durable queue, an outbox, or a persistent event store;
* any delivery guarantee across process crashes, and no exactly-once semantics;
* a Redis or database `IdempotencyStore` implementation;
* a metrics exporter or tracing integration;
* an authentication layer — pass credentials yourself via `RouterConfig.headers`;
* any transport other than an HTTP POST with a JSON body;
* visibility into transport-retry counts — `RouteResult.attempts` counts only
  application-level attempts;
* asynchronous delivery — `route` blocks until the destination answers or the
  timeout expires, so a slow destination applies backpressure directly to the
  caller.

Before depending on this in production, decide how you will handle a durable
store and its eviction policy, what your service does with a `TransportError`,
whether `statusRetry` is safe for each destination, credentials and TLS for
destination URLs, and per-destination breaker tuning — the defaults are
conservative rather than measured.

## Development and testing

```bash
bal test --code-coverage        # the library
bash scripts/build-all.sh       # library, local publish, then all three examples
bash scripts/release-check.sh   # pre-publication gate; exits non-zero if not ready
```

Every failure mode is produced by a local mock: an HTTP service covering
`202`/`400`/`500`/flaky/slow responses, and a `ballerina/tcp` listener that
accepts a connection and closes it without responding. No test depends on
network conditions.

`tests/concurrency_test.bal` exercises the idempotency guarantee under
contention with 100 concurrent strands.

Measured on Ballerina `2201.13.5`:

```text
bal test --code-coverage        # library
51 passing, 0 failing, 0 skipped
coverage: 98.40% (307 covered, 5 missed)

examples/basic-webhook           4 passing, 0 failing
examples/generic-iot             3 passing, 0 failing
examples/sotercare              11 passing, 0 failing
```

Commands, outputs and the live smoke test are recorded in
[VALIDATION_REPORT.md](VALIDATION_REPORT.md); design decisions and the sources
behind them are in [RESEARCH_NOTES.md](RESEARCH_NOTES.md); raw JSON reports are
in [evidence/](evidence).

## Versioning

`0.1.0`. The public API may change before `1.0.0`; treat minor version bumps
below `1.0.0` as potentially breaking.

## License

Apache-2.0. See [LICENSE](LICENSE).
