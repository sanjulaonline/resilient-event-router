// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/test;

@test:Config
function testEmptyDestinationUrlIsRejected() {
    Router|ConfigError router = new ({destinationUrl: ""});
    test:assertTrue(router is ConfigError, "expected a ConfigError");
}

@test:Config
function testNonHttpDestinationUrlIsRejected() {
    Router|ConfigError router = new ({destinationUrl: "ftp://example.com/hook"});
    test:assertTrue(router is ConfigError, "expected a ConfigError");
}

@test:Config
function testReservedDestinationNameIsRejected() {
    Router|ConfigError router = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        destinations: {[DEFAULT_DESTINATION]: {url: MOCK_BASE_URL + "/mock/ok"}}
    });
    test:assertTrue(router is ConfigError, "expected a ConfigError for a reserved destination name");
}

@test:Config
function testNonPositiveTimeoutIsRejected() {
    Router|ConfigError router = new ({destinationUrl: MOCK_BASE_URL + "/mock/ok", timeout: 0});
    test:assertTrue(router is ConfigError, "expected a ConfigError");
}

@test:Config
function testOutOfRangeResilienceSettingsAreRejected() {
    Router|ConfigError negativeRetries = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        transportRetry: {count: -1}
    });
    test:assertTrue(negativeRetries is ConfigError, "transportRetry.count must not be negative");

    Router|ConfigError badBackOff = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        transportRetry: {backOffFactor: 0.5}
    });
    test:assertTrue(badBackOff is ConfigError, "transportRetry.backOffFactor must be at least 1.0");

    Router|ConfigError badThreshold = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        circuitBreaker: {failureThreshold: 1.5}
    });
    test:assertTrue(badThreshold is ConfigError, "failureThreshold must be in (0, 1]");

    Router|ConfigError badWindow = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        circuitBreaker: {timeWindow: 2, bucketSize: 10}
    });
    test:assertTrue(badWindow is ConfigError, "bucketSize must not exceed timeWindow");

    Router|ConfigError badStatusRetry = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        statusRetry: {maxElapsedTime: 0}
    });
    test:assertTrue(badStatusRetry is ConfigError, "statusRetry.maxElapsedTime must be positive");
}

@test:Config
function testNamedDestinationUrlIsValidated() {
    Router|ConfigError router = new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        destinations: {audit: {url: "not-a-url"}}
    });
    test:assertTrue(router is ConfigError, "expected a ConfigError");
    if router is ConfigError {
        test:assertEquals(router.detail()?.destination, "audit");
    }
}

@test:Config
function testDefaultsAreAccepted() returns error? {
    Router router = check new ({destinationUrl: MOCK_BASE_URL + "/mock/ok"});
    test:assertEquals(router.destinationNames(), [DEFAULT_DESTINATION]);
}

// One assertion per validation guard in validateConfig. These are the branches
// that silently stop protecting anything if a guard is deleted.
@test:Config
function testEveryValidationGuardRejectsItsOwnCase() {
    string url = MOCK_BASE_URL + "/mock/ok";

    Router|ConfigError emptyName = new ({destinationUrl: url, destinations: {"  ": {url}}});
    test:assertTrue(emptyName is ConfigError, "a blank destination name must be rejected");

    Router|ConfigError negativeInterval = new ({destinationUrl: url, transportRetry: {interval: -1}});
    test:assertTrue(negativeInterval is ConfigError, "transportRetry.interval must not be negative");

    Router|ConfigError shortMaxWait = new ({
        destinationUrl: url,
        transportRetry: {interval: 2, maxWaitInterval: 1}
    });
    test:assertTrue(shortMaxWait is ConfigError, "maxWaitInterval must not be below interval");

    Router|ConfigError zeroWindow = new ({destinationUrl: url, circuitBreaker: {timeWindow: 0}});
    test:assertTrue(zeroWindow is ConfigError, "circuitBreaker.timeWindow must be positive");

    Router|ConfigError zeroBucket = new ({destinationUrl: url, circuitBreaker: {bucketSize: 0}});
    test:assertTrue(zeroBucket is ConfigError, "circuitBreaker.bucketSize must be positive");

    Router|ConfigError zeroVolume = new ({destinationUrl: url, circuitBreaker: {requestVolumeThreshold: 0}});
    test:assertTrue(zeroVolume is ConfigError, "requestVolumeThreshold must be at least 1");

    Router|ConfigError zeroReset = new ({destinationUrl: url, circuitBreaker: {resetTime: 0}});
    test:assertTrue(zeroReset is ConfigError, "circuitBreaker.resetTime must be positive");

    Router|ConfigError negativeStatusCount = new ({destinationUrl: url, statusRetry: {count: -1}});
    test:assertTrue(negativeStatusCount is ConfigError, "statusRetry.count must not be negative");

    Router|ConfigError noStatusCodes = new ({
        destinationUrl: url,
        statusRetry: {statusCodes: [], count: 2}
    });
    test:assertTrue(noStatusCodes is ConfigError, "statusRetry with retries but no codes is meaningless");

    Router|ConfigError negativeStatusInterval = new ({destinationUrl: url, statusRetry: {interval: -1}});
    test:assertTrue(negativeStatusInterval is ConfigError, "statusRetry.interval must not be negative");

    Router|ConfigError badStatusBackOff = new ({destinationUrl: url, statusRetry: {backOffFactor: 0.5}});
    test:assertTrue(badStatusBackOff is ConfigError, "statusRetry.backOffFactor must be at least 1.0");

    Router|ConfigError shortStatusMax = new ({
        destinationUrl: url,
        statusRetry: {interval: 3, maxInterval: 1}
    });
    test:assertTrue(shortStatusMax is ConfigError, "statusRetry.maxInterval must not be below interval");
}

// statusRetry.count 0 with an empty statusCodes list is a valid way to say
// "never retry a status code", so it must not be rejected.
@test:Config
function testDisabledStatusRetryWithNoCodesIsAccepted() returns error? {
    Router router = check new ({
        destinationUrl: MOCK_BASE_URL + "/mock/ok",
        statusRetry: {statusCodes: [], count: 0}
    });
    RouteResult result = check router.route({id: "evt-status-retry-off", eventType: "app.event"});
    test:assertTrue(result.delivered);
}
