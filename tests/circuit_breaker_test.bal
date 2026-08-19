// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/lang.runtime;
import ballerina/test;

@test:Config
function testBreakerOpensAfterRepeatedFailures() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: {
            timeWindow: 60,
            bucketSize: 10,
            requestVolumeThreshold: 3,
            failureThreshold: 0.1,
            resetTime: 60,
            statusCodes: [500]
        }
    });

    foreach int i in 0 ..< 3 {
        RouteResult|RouterError result = router.route({id: "evt-cb-" + i.toString(), eventType: "app.event"});
        test:assertTrue(result is DownstreamError, "attempt " + i.toString() + " should reach the destination");
    }
    test:assertEquals(requestCount("fail500"), 3);

    RouteResult|RouterError blocked = router.route({id: "evt-cb-open", eventType: "app.event"});
    test:assertTrue(blocked is CircuitOpenError, "expected a CircuitOpenError once the breaker trips");
    test:assertEquals(requestCount("fail500"), 3, "an open breaker must not send a request");
    // A request the breaker refused to send has not been processed anywhere,
    // so the event id stays available.
    test:assertFalse(check router.isRouted("evt-cb-open"));
}

@test:Config
function testBreakerRecoversAfterResetTime() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/flaky",
        transportRetry: {count: 0},
        circuitBreaker: {
            timeWindow: 60,
            bucketSize: 10,
            requestVolumeThreshold: 2,
            failureThreshold: 0.1,
            resetTime: 1,
            statusCodes: [503]
        }
    });

    // The flaky destination answers 503 twice for a given event id and then
    // accepts it. Two failures reach the volume threshold and trip the breaker;
    // because each failure releases the event id, the same id can be reused.
    RouteResult|RouterError first = router.route({id: "evt-cb-r1", eventType: "app.event"});
    RouteResult|RouterError second = router.route({id: "evt-cb-r1", eventType: "app.event"});
    test:assertTrue(first is DownstreamError, "the first request should get a 503");
    test:assertTrue(second is DownstreamError, "the second request should get a 503");
    test:assertEquals(requestCount("flaky"), 2);

    RouteResult|RouterError blocked = router.route({id: "evt-cb-r2", eventType: "app.event"});
    test:assertTrue(blocked is CircuitOpenError, "expected the breaker to be open");
    test:assertEquals(requestCount("flaky"), 2, "an open breaker must not send a request");

    runtime:sleep(1.5);

    // Half-open: the trial request is sent. evt-cb-r1 has used both of its
    // forced failures, so the destination accepts it and the breaker closes.
    RouteResult|RouterError trial = router.route({id: "evt-cb-r1", eventType: "app.event"});
    test:assertTrue(trial is RouteResult, "expected the trial request to be sent after resetTime");
    test:assertEquals(requestCount("flaky"), 3);
}

@test:Config
function testCircuitBreakerCanBeDisabled() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: ()
    });

    foreach int i in 0 ..< 5 {
        RouteResult|RouterError result = router.route({id: "evt-nocb-" + i.toString(), eventType: "app.event"});
        test:assertTrue(result is DownstreamError, "every request must be sent when the breaker is disabled");
    }
    test:assertEquals(requestCount("fail500"), 5);
}

// Pins down the assumption behind the typed circuit-open check in delivery.bal:
// ballerina/http wraps the retry client inside the circuit-breaker client, so an
// open breaker still surfaces as http:UpstreamServiceUnavailableError and never
// as a retry failure. Without this ordering the error would be classified as a
// TransportError instead.
@test:Config
function testCircuitOpenIsDetectedWithTransportRetryEnabled() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 2, interval: 0.01, maxWaitInterval: 0.05},
        circuitBreaker: {
            timeWindow: 60,
            bucketSize: 10,
            requestVolumeThreshold: 2,
            failureThreshold: 0.1,
            resetTime: 60,
            statusCodes: [500]
        }
    });

    foreach int i in 0 ..< 2 {
        RouteResult|RouterError seed = router.route({id: "evt-cbr-" + i.toString(), eventType: "app.event"});
        test:assertTrue(seed is DownstreamError, "seed request " + i.toString() + " should reach the destination");
    }

    RouteResult|RouterError blocked = router.route({id: "evt-cbr-open", eventType: "app.event"});
    test:assertTrue(blocked is CircuitOpenError,
            "an open breaker must stay a CircuitOpenError when transport retry is enabled");
    test:assertFalse(blocked is TransportError, "circuit-open must not be reported as a transport failure");
    test:assertEquals(requestCount("fail500"), 2, "an open breaker must not send a request");
}
