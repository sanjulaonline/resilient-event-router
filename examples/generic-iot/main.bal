// Generic IoT consumer of sanjulaonline/resilient_event_router.
//
// Shows the two extension points: a classifier turns a device reading into a
// severity, and a routing rule sends urgent readings to a paging endpoint and
// everything else to a telemetry endpoint.
//
//   bal run -- -CtelemetryUrl=... -CpagingUrl=...

import ballerina/io;

import sanjulaonline/resilient_event_router as router;

configurable string telemetryUrl = "http://localhost:8291/telemetry";
configurable string pagingUrl = "http://localhost:8291/paging";

const string PAGING = "paging";

// Reading thresholds live in the application, not in the router.
isolated function classifyReading(router:Event event) returns router:Severity {
    json|error temperature = event.payload.temperature;
    if temperature is error {
        return router:INFO;
    }
    // Accepts float, decimal or int, so the same rule works for readings that
    // were parsed from JSON and for readings built in code.
    float|error value = float:fromString(temperature.toString());
    if value is error {
        return router:INFO;
    }
    if value >= 80.0 {
        return router:CRITICAL;
    }
    if value >= 60.0 {
        return router:WARNING;
    }
    return router:INFO;
}

isolated function routeBySeverity(router:Event event, router:Severity severity) returns string? =>
    severity == router:CRITICAL ? PAGING : router:DEFAULT_DESTINATION;

isolated function newDeviceRouter() returns router:Router|router:ConfigError => new ({
    destinationUrl: telemetryUrl,
    destinations: {[PAGING]: {url: pagingUrl}},
    classifier: classifyReading,
    routingRule: routeBySeverity,
    timeout: 2,
    transportRetry: {count: 3, interval: 0.1, maxWaitInterval: 1}
});

public function main() returns error? {
    router:Router deviceRouter = check newDeviceRouter();

    router:Event[] readings = [
        {id: "sensor-555", eventType: "temperature.alert", payload: {deviceId: "temperature-01", temperature: 82.3}},
        {id: "sensor-556", eventType: "temperature.reading", payload: {deviceId: "temperature-02", temperature: 21.4}}
    ];

    foreach router:Event reading in readings {
        router:RouteResult|router:RouterError result = deviceRouter.route(reading);
        if result is router:RouterError {
            io:println(reading.id, " failed: ", result.message());
            continue;
        }
        io:println(reading.id, " -> ", result.destination ?: "-", " severity ", result.severity);
    }
}
