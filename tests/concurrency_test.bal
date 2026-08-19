// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.
//
// The idempotency contract states that reserve() is atomic: for a given id
// exactly one concurrent caller may receive true. These tests measure that
// claim under contention rather than arguing it from the lock.
//
// The detection power was checked by substitution: a store that reproduces the
// original check-then-act shape (read, 1 ms gap, write) makes 92 of these 100
// callers all win the same id, so the assertions below can genuinely fail. See
// VALIDATION_REPORT.md.

import ballerina/test;

const int CONCURRENT_WORKERS = 100;

// Same id, many workers. Exactly one may win.
@test:Config
function testConcurrentReserveHasExactlyOneWinner() returns error? {
    InMemoryIdempotencyStore store = new;
    future<boolean|error>[] attempts = [];

    foreach int i in 0 ..< CONCURRENT_WORKERS {
        future<boolean|error> attempt = start store.reserve("contended-id");
        attempts.push(attempt);
    }

    int won = 0;
    int lost = 0;
    foreach future<boolean|error> attempt in attempts {
        boolean reserved = check wait attempt;
        if reserved {
            won += 1;
        } else {
            lost += 1;
        }
    }

    test:assertEquals(won, 1, "exactly one concurrent caller may reserve an id");
    test:assertEquals(lost, CONCURRENT_WORKERS - 1, "every other caller must be told the id is taken");
    test:assertEquals(store.size(), 1, "one contended id must leave exactly one reservation");
}

// Distinct ids, many workers. Every reservation must survive; a map mutated
// without a lock would lose writes here.
@test:Config
function testConcurrentReservesOfDistinctIdsAllSucceed() returns error? {
    InMemoryIdempotencyStore store = new;
    future<boolean|error>[] attempts = [];

    foreach int i in 0 ..< CONCURRENT_WORKERS {
        future<boolean|error> attempt = start store.reserve("distinct-" + i.toString());
        attempts.push(attempt);
    }

    int won = 0;
    foreach future<boolean|error> attempt in attempts {
        boolean reserved = check wait attempt;
        if reserved {
            won += 1;
        }
    }

    test:assertEquals(won, CONCURRENT_WORKERS, "distinct ids must not contend with each other");
    test:assertEquals(store.size(), CONCURRENT_WORKERS, "no reservation may be lost to a concurrent write");
}

// The end-to-end guarantee a caller actually depends on: the same event routed
// concurrently reaches the destination once. The outbound HTTP call gives the
// scheduler real yield points, so the strands genuinely interleave here.
@test:Config
function testConcurrentRouteDeliversTheSameEventOnce() returns error? {
    Router router = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok"});
    future<RouteResult|RouterError>[] attempts = [];

    foreach int i in 0 ..< CONCURRENT_WORKERS {
        future<RouteResult|RouterError> attempt = start router.route({
            id: "evt-contended",
            eventType: "app.event"
        });
        attempts.push(attempt);
    }

    int delivered = 0;
    int duplicates = 0;
    int unexpected = 0;
    foreach future<RouteResult|RouterError> attempt in attempts {
        RouteResult|RouterError result = wait attempt;
        if result is RouteResult {
            delivered += 1;
        } else if result is DuplicateEventError {
            duplicates += 1;
        } else {
            unexpected += 1;
        }
    }

    test:assertEquals(delivered, 1, "one concurrent caller may route the event");
    test:assertEquals(duplicates, CONCURRENT_WORKERS - 1, "every other caller must see a DuplicateEventError");
    test:assertEquals(unexpected, 0, "no other error is expected against a healthy destination");
    test:assertEquals(requestCount("ok"), 1, "the destination must receive the event exactly once");
}

// A failed delivery releases the id, so under contention against a failing
// destination every caller must be able to try: no caller may be turned away
// as a duplicate of an event that was never delivered.
@test:Config
function testConcurrentRouteAgainstAFailingDestinationLeavesNoReservation() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/fail500",
        transportRetry: {count: 0},
        circuitBreaker: ()
    });
    future<RouteResult|RouterError>[] attempts = [];

    foreach int i in 0 ..< 20 {
        future<RouteResult|RouterError> attempt = start router.route({
            id: "evt-contended-failure",
            eventType: "app.event"
        });
        attempts.push(attempt);
    }

    int failures = 0;
    foreach future<RouteResult|RouterError> attempt in attempts {
        RouteResult|RouterError result = wait attempt;
        if result is DownstreamError || result is DuplicateEventError {
            failures += 1;
        }
    }

    test:assertEquals(failures, 20, "every caller must get a typed failure, none a delivery");
    test:assertFalse(check router.isRouted("evt-contended-failure"),
            "no reservation may survive when every delivery failed");
}
