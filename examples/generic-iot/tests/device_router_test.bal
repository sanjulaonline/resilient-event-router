import ballerina/http;
import ballerina/test;

import sanjulaonline/resilient_event_router as router;

isolated map<int> hits = {};

isolated function hitCount(string route) returns int {
    lock {
        return hits[route] ?: 0;
    }
}

service on new http:Listener(8291) {
    isolated resource function post telemetry(@http:Payload json envelope) returns http:Accepted {
        lock {
            hits["telemetry"] = (hits["telemetry"] ?: 0) + 1;
        }
        return {body: {status: "ok"}};
    }

    isolated resource function post paging(@http:Payload json envelope) returns http:Accepted {
        lock {
            hits["paging"] = (hits["paging"] ?: 0) + 1;
        }
        return {body: {status: "paged"}};
    }
}

@test:Config
function testHotReadingIsPaged() returns error? {
    router:Router deviceRouter = check newDeviceRouter();
    router:RouteResult result = check deviceRouter.route({
        id: "sensor-555",
        eventType: "temperature.alert",
        payload: {deviceId: "temperature-01", temperature: 82.3}
    });

    test:assertEquals(result.severity, router:CRITICAL);
    test:assertEquals(result.destination, PAGING);
    test:assertTrue(result.delivered);
    test:assertEquals(hitCount("paging"), 1);
}

@test:Config
function testNormalReadingGoesToTelemetry() returns error? {
    router:Router deviceRouter = check newDeviceRouter();
    router:RouteResult result = check deviceRouter.route({
        id: "sensor-556",
        eventType: "temperature.reading",
        payload: {deviceId: "temperature-02", temperature: 21.4}
    });

    test:assertEquals(result.severity, router:INFO);
    test:assertEquals(result.destination, router:DEFAULT_DESTINATION);
    test:assertEquals(hitCount("telemetry"), 1);
}

@test:Config
function testWarningThreshold() {
    test:assertEquals(classifyReading({id: "s", eventType: "t", payload: {temperature: 65}}), router:WARNING);
    test:assertEquals(classifyReading({id: "s", eventType: "t", payload: {}}), router:INFO);
}
