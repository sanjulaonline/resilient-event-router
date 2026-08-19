// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/test;

@test:Config
function testDuplicateEventIsRejected() returns error? {
    Router router = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok"});

    RouteResult first = check router.route({id: "evt-dup", eventType: "app.event"});
    RouteResult|RouterError second = router.route({id: "evt-dup", eventType: "app.event"});

    test:assertTrue(first.delivered);
    test:assertTrue(second is DuplicateEventError, "expected a DuplicateEventError");
    if second is DuplicateEventError {
        test:assertEquals(second.detail()?.eventId, "evt-dup");
    }
    test:assertEquals(requestCount("ok"), 1, "a duplicate must not reach the destination");
}

@test:Config
function testFailedDeliveryReleasesTheEventId() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        circuitBreaker: ()
    });

    RouteResult|RouterError failed = router.route({id: "evt-retryable", eventType: "app.event"});
    test:assertTrue(failed is DownstreamError, "expected a DownstreamError");
    test:assertFalse(check router.isRouted("evt-retryable"),
            "a failed delivery must not permanently consume the event id");
}

@test:Config
function testCallerCanRetryAfterAFailedDelivery() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/flaky",
        transportRetry: {count: 0},
        circuitBreaker: ()
    });

    // The flaky destination fails twice per event id before accepting.
    RouteResult|RouterError first = router.route({id: "evt-replay", eventType: "app.event"});
    RouteResult|RouterError second = router.route({id: "evt-replay", eventType: "app.event"});
    RouteResult|RouterError third = router.route({id: "evt-replay", eventType: "app.event"});

    test:assertTrue(first is DownstreamError);
    test:assertTrue(second is DownstreamError);
    test:assertTrue(third is RouteResult, "the same event id must be usable until it succeeds");
    test:assertTrue(check router.isRouted("evt-replay"));
}

@test:Config
function testForgetAllowsReprocessing() returns error? {
    Router router = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok"});

    _ = check router.route({id: "evt-forget", eventType: "app.event"});
    test:assertTrue(check router.isRouted("evt-forget"));

    check router.forget("evt-forget");
    test:assertFalse(check router.isRouted("evt-forget"));

    _ = check router.route({id: "evt-forget", eventType: "app.event"});
    test:assertEquals(requestCount("ok"), 2);
}

@test:Config
function testInMemoryStoreReserveIsSingleWinner() returns error? {
    InMemoryIdempotencyStore store = new;

    test:assertTrue(check store.reserve("a"));
    test:assertFalse(check store.reserve("a"));
    test:assertTrue(check store.contains("a"));
    test:assertEquals(store.size(), 1);

    check store.release("a");
    test:assertFalse(check store.contains("a"));
    // Releasing an absent id is not an error.
    check store.release("a");

    _ = check store.reserve("b");
    store.clear();
    test:assertEquals(store.size(), 0);
}

@test:Config
function testSuppliedStoreIsUsed() returns error? {
    InMemoryIdempotencyStore shared = new;
    Router first = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok", idempotencyStore: shared});
    Router second = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok", idempotencyStore: shared});

    _ = check first.route({id: "evt-shared", eventType: "app.event"});
    RouteResult|RouterError duplicate = second.route({id: "evt-shared", eventType: "app.event"});

    test:assertTrue(duplicate is DuplicateEventError,
            "two routers sharing a store must see each other's reservations");
    test:assertEquals(shared.size(), 1);
}

@test:Config
function testFailingStoreSurfacesAsIdempotencyStoreError() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        idempotencyStore: new FailingStore()
    });

    RouteResult|RouterError result = router.route({id: "evt-store-down", eventType: "app.event"});
    test:assertTrue(result is IdempotencyStoreError, "expected an IdempotencyStoreError");
    test:assertEquals(requestCount("ok"), 0);
}

isolated class FailingStore {
    *IdempotencyStore;

    public isolated function reserve(string eventId) returns boolean|error =>
        error("store unavailable");

    public isolated function release(string eventId) returns error? =>
        error("store unavailable");

    public isolated function contains(string eventId) returns boolean|error =>
        error("store unavailable");
}

// isRouted and forget must surface a store outage as a typed error rather than
// silently answering false or swallowing it.
@test:Config
function testStoreOutageSurfacesFromIsRoutedAndForget() {
    Router|ConfigError router = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        idempotencyStore: new FailingStore()
    });
    if router !is Router {
        test:assertFail("router should have been created");
    }

    boolean|RouterError present = router.isRouted("evt-any");
    test:assertTrue(present is IdempotencyStoreError, "isRouted must report a store outage");

    RouterError? forgotten = router.forget("evt-any");
    test:assertTrue(forgotten is IdempotencyStoreError, "forget must report a store outage");
}

// A store that accepts reservations but cannot release them. The router must
// still return the delivery error rather than failing on the release path.
isolated class UnreleasableStore {
    *IdempotencyStore;

    private final InMemoryIdempotencyStore inner = new;

    public isolated function reserve(string eventId) returns boolean|error => self.inner.reserve(eventId);

    public isolated function release(string eventId) returns error? => error("release unavailable");

    public isolated function contains(string eventId) returns boolean|error => self.inner.contains(eventId);
}

@test:Config
function testReleaseFailureDoesNotMaskTheDeliveryError() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        circuitBreaker: (),
        idempotencyStore: new UnreleasableStore()
    });

    RouteResult|RouterError result = router.route({id: "evt-stuck", eventType: "app.event"});
    test:assertTrue(result is DownstreamError,
            "the delivery error must survive a failed release");
    if result is DownstreamError {
        test:assertEquals(result.detail()?.statusCode, 500);
    }
}
