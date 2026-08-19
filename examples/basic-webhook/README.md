# Example: basic webhook

The smallest consumer of `sanjula/resilient_event_router`. It sends one
application event to an HTTP webhook and handles the typed outcome.

```text
application event  ->  resilient_event_router  ->  HTTP webhook
```

This package is also the **consumer test** for the library: it depends on the
published package and uses only its public API, so it fails if the public
surface changes in a breaking way.

## Prerequisites

Publish the library to the Ballerina local repository first:

```bash
cd ../..
bal pack
bal push --repository=local
```

## Run the tests

The tests start a webhook receiver on port `8290` and route events through it.

```bash
bal test
```

They cover a successful delivery, the envelope contents, a duplicate event, a
downstream `500`, and an invalid configuration.

## Run the program

`main` needs a receiver. Point it at any endpoint that accepts a JSON POST:

```bash
bal run -- -CwebhookUrl=http://localhost:8290/hook
```

Event sent:

```json
{
  "id": "order-123",
  "eventType": "order.created",
  "payload": { "orderId": "123", "amount": 145.50 }
}
```

The receiver sees the envelope the library produces:

```json
{
  "id": "order-123",
  "eventType": "order.created",
  "severity": "WARNING",
  "metadata": { "origin": "checkout-api" },
  "payload": { "orderId": "123", "amount": 145.5 }
}
```
