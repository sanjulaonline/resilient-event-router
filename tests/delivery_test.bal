// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/test;

@test:Config
function testUnreachableDestinationIsATransportError() returns error? {
    Router router = check new ({
        destinationUrl: UNREACHABLE_URL,
        transportRetry: {count: 0},
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-unreachable", eventType: "app.event"});
    test:assertTrue(result is TransportError, "expected a TransportError");
    if result is TransportError {
        test:assertEquals(result.detail()?.statusCode, ());
        test:assertEquals(result.detail()?.destination, DEFAULT_DESTINATION);
    }
}

@test:Config
function testTimeoutIsATransportError() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/slow",
        timeout: 0.3,
        transportRetry: {count: 0},
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-timeout", eventType: "app.event"});
    test:assertTrue(result is TransportError, "expected a TransportError for a request that exceeds the timeout");
    // The request did reach the destination; only the response was too late.
    test:assertEquals(requestCount("slow"), 1);
}

@test:Config
function testHttpFiveHundredIsADownstreamError() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-500", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError");
    test:assertFalse(result is TransportError, "an HTTP response is not a transport failure");
    if result is DownstreamError {
        test:assertEquals(result.detail()?.statusCode, 500);
        test:assertEquals(result.detail()?.attempts, 1);
    }
}

@test:Config
function testHttpFourHundredIsADownstreamError() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail400",
        circuitBreaker: ()
    });

    RouteResult|RouterError result = router.route({id: "evt-400", eventType: "app.event"});
    test:assertTrue(result is DownstreamError, "expected a DownstreamError");
    if result is DownstreamError {
        test:assertEquals(result.detail()?.statusCode, 400);
    }
}

@test:Config
function testDestinationPathAndQueryArePreserved() returns error? {
    Router router = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok"});
    RouteResult result = check router.route({id: "evt-path", eventType: "app.event"});
    test:assertTrue(result.delivered);
    test:assertEquals(requestCount("ok"), 1);
}

@test:Config
function testSplitUrlHandlesPathsAndBareOrigins() {
    [string, string] withPath = splitUrl("https://example.com/hooks/events");
    test:assertEquals(withPath[0], "https://example.com");
    test:assertEquals(withPath[1], "/hooks/events");

    [string, string] bare = splitUrl("https://example.com");
    test:assertEquals(bare[0], "https://example.com");
    test:assertEquals(bare[1], "/");

    [string, string] withQuery = splitUrl("http://localhost:9091/hook?source=router");
    test:assertEquals(withQuery[0], "http://localhost:9091");
    test:assertEquals(withQuery[1], "/hook?source=router");
}
