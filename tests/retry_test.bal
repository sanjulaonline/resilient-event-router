// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.
//
// These tests pin down the distinction the package is built around:
// TransportRetryConfig retries transport failures, and never retries an HTTP response.

import ballerina/test;

// Regression test. The original project assumed the configured HTTP retry
// policy would retry a downstream 500. It does not: a 500 is a completed HTTP
// exchange, not a broken connection. The destination must see exactly one
// request.
@test:Config
function testHttpFiveHundredIsNotRetriedByTransportRetry() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 3, interval: 0.01, maxWaitInterval: 0.05},
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-500-no-retry", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError");
    test:assertEquals(requestCount("fail500"), 1,
            "TransportRetryConfig must not retry an HTTP 500 response");
}

// A connection that is accepted and then closed without an HTTP response is a
// transport failure, so TransportRetryConfig does apply. The TCP mock counts every
// connection attempt.
@test:Config
function testTransportFailureIsRetried() returns error? {
    Router router = check new ({
        destinationUrl: CLOSING_URL,
        transportRetry: {count: 2, interval: 0.01, maxWaitInterval: 0.05},
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-transport-retry", eventType: "app.event"});
    test:assertTrue(result is TransportError, "expected a TransportError");
    test:assertEquals(requestCount("tcp"), 3,
            "one initial attempt plus two transport-level retries");
}

@test:Config
function testTransportRetryCanBeDisabled() returns error? {
    Router router = check new ({
        destinationUrl: CLOSING_URL,
        transportRetry: {count: 0},
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-no-transport-retry", eventType: "app.event"});
    test:assertTrue(result is TransportError, "expected a TransportError");
    test:assertEquals(requestCount("tcp"), 1, "transportRetry.count 0 must make exactly one attempt");
}

// Opt-in, application-level retry of selected status codes.
@test:Config
function testStatusRetryRecoversFromRepeatedFiveZeroThree() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/flaky",
        transportRetry: {count: 0},
        circuitBreaker: (),
        statusRetry: {statusCodes: [503], count: 3, interval: 0.01, maxInterval: 0.05, maxElapsedTime: 5}
    });

    RouteResult result = check router.route({id: "evt-flaky", eventType: "app.event"});
    test:assertTrue(result.delivered);
    test:assertEquals(result.attempts, 3, "two 503 responses then a 202");
    test:assertEquals(result.statusCode, 202);
    test:assertEquals(requestCount("flaky"), 3);
}

@test:Config
function testStatusRetryOnlyAppliesToConfiguredCodes() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: (),
        statusRetry: {statusCodes: [503], count: 3, interval: 0.01, maxInterval: 0.05}
    });

    RouteResult|RouterError result = router.route({id: "evt-500-not-listed", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError");
    test:assertEquals(requestCount("fail500"), 1, "500 is not in statusRetry.statusCodes");
}

@test:Config
function testStatusRetryIsBoundedByAttemptCount() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: (),
        statusRetry: {statusCodes: [500], count: 2, interval: 0.01, maxInterval: 0.05, maxElapsedTime: 5}
    });

    RouteResult|RouterError result = router.route({id: "evt-500-bounded", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError after the retry budget is spent");
    if result is DownstreamError {
        test:assertEquals(result.detail()?.attempts, 3);
    }
    test:assertEquals(requestCount("fail500"), 3, "one initial attempt plus two status retries");
}

@test:Config
function testStatusRetryIsBoundedByElapsedTime() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: (),
        statusRetry: {
            statusCodes: [500],
            count: 20,
            interval: 0.4,
            backOffFactor: 1.0,
            maxInterval: 0.4,
            maxElapsedTime: 1
        }
    });

    RouteResult|RouterError result = router.route({id: "evt-500-time-bound", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError once the time budget is spent");
    int attempts = requestCount("fail500");
    test:assertTrue(attempts >= 2 && attempts <= 4,
            "the time budget must stop retrying well before the attempt budget, got " + attempts.toString());
}
