# Example: generic IoT

Shows both extension points of `sanjula/resilient_event_router` on device
telemetry that has nothing to do with healthcare.

```text
device reading
      |
      v
classifier      (application decides the severity from the temperature)
      |
      v
routing rule    (CRITICAL -> paging, everything else -> telemetry)
      |
      v
resilient_event_router  ->  HTTP destination
```

Thresholds live in `classifyReading` in [main.bal](main.bal). The library never
looks at the payload.

## Prerequisites

```bash
cd ../..
bal pack
bal push --repository=local
```

## Run the tests

The tests start both destinations on port `8291`.

```bash
bal test
```

## Run the program

```bash
bal run -- -CtelemetryUrl=http://localhost:8291/telemetry -CpagingUrl=http://localhost:8291/paging
```

Events sent:

```json
{ "id": "sensor-555", "eventType": "temperature.alert",   "payload": { "deviceId": "temperature-01", "temperature": 82.3 } }
{ "id": "sensor-556", "eventType": "temperature.reading", "payload": { "deviceId": "temperature-02", "temperature": 21.4 } }
```

The first is classified `CRITICAL` and goes to the paging destination; the
second is `INFO` and goes to telemetry.
