# Example: SoterCare Alert Router

The original project this repository grew out of, refactored into a consumer of
`sanjula/resilient_event_router`.

This is an engineering prototype built with synthetic data. It is not a medical
device, a clinical decision system, or a production alerting service. The
thresholds in [domain.bal](domain.bal) exist to exercise routing branches and
have not been clinically reviewed.

## The separation this example demonstrates

```text
sensor payload
      |
      v
SoterCare validation          domain.bal   "is this reading well formed?"
      |
      v
SoterCare classification      domain.bal   "what does this reading mean?"
      |
      v
resilient_event_router        library      "how do I deliver it safely?"
      |
      v
mock notifier
```

SoterCare owns the four-level `CareSeverity` (`normal`, `medium`, `high`,
`critical`), the sensor thresholds and the HTTP contract. The library owns
duplicate suppression, the outbound timeout, transport retries, backoff,
circuit breaking and the typed error model.

The mapping between the two layers is three small functions in
[domain.bal](domain.bal):

| Function | Responsibility |
| --- | --- |
| `toRouterSeverity` | Four care severities to the router's three transport severities |
| `toRouterEvent` | Sensor reading to a domain-neutral `router:Event`, with the SoterCare route carried in `metadata` |
| `routeByCareDecision` | The `router:RoutingRule`: caregiver events are delivered, everything else is recorded locally |

## Prerequisites

```bash
cd ../..
bal pack
bal push --repository=local
```

## Run

```bash
bal test
bal build
bal run
```

The API listener starts on `9090`; the mock notifier starts on `9091`.

```bash
curl http://localhost:9090/api/v1/health
curl -i -H 'content-type: application/json' --data @samples/normal-vitals.json  http://localhost:9090/api/v1/events
curl -i -H 'content-type: application/json' --data @samples/critical-fall.json  http://localhost:9090/api/v1/events
bash scripts/smoke-test.sh
```

## HTTP outcomes

| Status | When |
| --- | --- |
| `202 Accepted` | Validated, classified, and either delivered or recorded locally |
| `400 Invalid Request` | Malformed JSON (payload binding) or failed domain validation |
| `409 Duplicate Event` | The router's idempotency store already holds the `eventId` |
| `503 Notifier Unavailable` | Any `router:DeliveryError`; the `eventId` was released so the caller can retry |

The `202` body reports both layers:

```json
{
  "eventId": "fall-demo-001",
  "status": "accepted",
  "severity": "critical",
  "routedTo": "caregiver-notifier",
  "notified": true,
  "correlationId": "fall-demo-001"
}
```

`severity` and `routedTo` are SoterCare's decision. `notified` is the library's
`RouteResult.delivered`.

## Reproduce the negative cases

### Duplicate event

Post `samples/critical-fall.json` twice. The first call returns `202`; the
second returns `409` with `"code": "DUPLICATE_EVENT"`.

### Permanent downstream failure

Event ids beginning with `fail-` make the mock notifier return HTTP `500`:

```bash
curl -i -H 'content-type: application/json' --data @samples/permanent-failure.json http://localhost:9090/api/v1/events
```

The library returns a `router:DownstreamError`, releases the event id, and the
service maps it to `503`. The same `eventId` can be retried.

### Malformed JSON

```bash
curl -i -H 'content-type: application/json' --data '{broken' http://localhost:9090/api/v1/events
```

Ballerina rejects the payload at the data-binding boundary with `400`, before
the resource body runs.

## What changed from the pre-library version

| Before | After |
| --- | --- |
| `state.bal` held an in-memory `processedEvents` map | The router's `InMemoryIdempotencyStore` holds it |
| `router.bal` built the resilient `http:Client` | `RouterConfig` describes it |
| Duplicate check ran before validation | Validation runs first, so an invalid event never consumes an id |
| The notifier received a SoterCare-shaped `NotificationRequest` | It receives the library's generic envelope |
| One untyped `error` from the notifier call | Typed `router:TransportError`, `router:DownstreamError`, `router:CircuitOpenError`, recorded in the failure log |

The public HTTP contract kept its status codes and error codes; only the
`202` body gained the `notified` field.

## Configuration

```bash
cp Config.toml.example Config.toml
```

```toml
servicePort = 9090
notifierPort = 9091
notifierBaseUrl = "http://localhost:9091"
```

`Config.toml` is git-ignored.

## Docker

Build from the repository root so the library can be published to the local
repository first:

```bash
docker build -f examples/sotercare/Dockerfile -t sotercare-alert-router .
docker run --rm -p 9090:9090 -p 9091:9091 sotercare-alert-router
```
