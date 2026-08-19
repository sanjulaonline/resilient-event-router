// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/test;

@test:BeforeEach
function resetBetweenTests() {
    resetMockState();
}

isolated function okRouter(RouterConfig extra = {destinationUrl: MOCK_BASE_URL + "/mock/ok"})
        returns Router|ConfigError => new Router(extra);

@test:Config
function testValidEventIsDelivered() returns error? {
    Router router = check okRouter();
    RouteResult result = check router.route({id: "evt-1", eventType: "order.created", payload: {orderId: "123"}},
            WARNING);

    test:assertEquals(result.eventId, "evt-1");
    test:assertEquals(result.eventType, "order.created");
    test:assertEquals(result.severity, WARNING);
    test:assertEquals(result.destination, DEFAULT_DESTINATION);
    test:assertTrue(result.delivered);
    test:assertEquals(result.attempts, 1);
    test:assertEquals(result.statusCode, 202);
    test:assertEquals(requestCount("ok"), 1);
}

@test:Config
function testEnvelopeCarriesSeverityMetadataAndPayload() returns error? {
    Router router = check okRouter();
    _ = check router.route({
        id: "evt-envelope",
        eventType: "temperature.alert",
        payload: {deviceId: "temperature-01", temperature: 82.3},
        metadata: {region: "eu-west-1", tenant: "acme"}
    }, CRITICAL);

    json envelope = envelopeFor("evt-envelope");
    test:assertEquals(check envelope.id, "evt-envelope");
    test:assertEquals(check envelope.eventType, "temperature.alert");
    test:assertEquals(check envelope.severity, "CRITICAL");
    test:assertEquals(check envelope.metadata.region, "eu-west-1");
    test:assertEquals(check envelope.payload.deviceId, "temperature-01");

    map<string> headers = headersFor("evt-envelope");
    test:assertEquals(headers["x-event-id"], "evt-envelope");
    test:assertEquals(headers["x-event-type"], "temperature.alert");
    test:assertEquals(headers["x-event-severity"], "CRITICAL");
}

@test:Config
function testConfiguredHeadersAreSent() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       headers: {"x-api-key": "test-key"}
                                   });
    _ = check router.route({id: "evt-headers", eventType: "app.event"});
    test:assertEquals(headersFor("evt-headers")["x-api-key"], "test-key");
}

@test:Config
function testDefaultSeverityIsInfo() returns error? {
    Router router = check okRouter();
    RouteResult result = check router.route({id: "evt-default-sev", eventType: "app.event"});
    test:assertEquals(result.severity, INFO);
}

@test:Config
function testClassifierSuppliesSeverity() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       classifier: isolated function(Event event) returns Severity =>
                                           event.eventType.endsWith(".failed") ? CRITICAL : INFO
                                   });

    RouteResult failed = check router.route({id: "evt-c1", eventType: "payment.failed"});
    RouteResult ok = check router.route({id: "evt-c2", eventType: "payment.settled"});
    test:assertEquals(failed.severity, CRITICAL);
    test:assertEquals(ok.severity, INFO);
}

@test:Config
function testExplicitSeverityOverridesClassifier() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       classifier: isolated function(Event event) returns Severity => INFO
                                   });
    RouteResult result = check router.route({id: "evt-override", eventType: "app.event"}, CRITICAL);
    test:assertEquals(result.severity, CRITICAL);
}

@test:Config
function testRoutingRuleSelectsNamedDestination() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       destinations: {urgent: {url: MOCK_BASE_URL + "/mock/ok", headers: {"x-lane": "urgent"}}},
                                       routingRule: isolated function(Event event, Severity severity) returns string? =>
                                           severity == CRITICAL ? "urgent" : DEFAULT_DESTINATION
                                   });

    RouteResult urgent = check router.route({id: "evt-urgent", eventType: "app.event"}, CRITICAL);
    RouteResult normal = check router.route({id: "evt-normal", eventType: "app.event"}, INFO);

    test:assertEquals(urgent.destination, "urgent");
    test:assertEquals(headersFor("evt-urgent")["x-lane"], "urgent");
    test:assertEquals(normal.destination, DEFAULT_DESTINATION);
    test:assertEquals(headersFor("evt-normal")["x-lane"], ());
}

@test:Config
function testRoutingRuleCanSuppressDelivery() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       routingRule: isolated function(Event event, Severity severity) returns string? =>
                                           severity == INFO ? () : DEFAULT_DESTINATION
                                   });

    RouteResult result = check router.route({id: "evt-suppressed", eventType: "app.event"}, INFO);
    test:assertEquals(result.destination, ());
    test:assertFalse(result.delivered);
    test:assertEquals(result.attempts, 0);
    test:assertEquals(result.statusCode, ());
    test:assertEquals(requestCount("ok"), 0);
    // A suppressed event is still recorded, so it cannot be routed twice.
    test:assertTrue(check router.isRouted("evt-suppressed"));
}

@test:Config
function testUnknownDestinationIsRejected() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       routingRule: isolated function(Event event, Severity severity) returns string? => "nowhere"
                                   });

    RouteResult|RouterError result = router.route({id: "evt-unknown-dest", eventType: "app.event"});
    test:assertTrue(result is InvalidDestinationError, "expected an InvalidDestinationError");
    if result is InvalidDestinationError {
        test:assertEquals(result.detail()?.destination, "nowhere");
    }
    // The reservation is released, so the id is still usable.
    test:assertFalse(check router.isRouted("evt-unknown-dest"));
}

@test:Config
function testEmptyEventIdIsRejected() returns error? {
    Router router = check okRouter();
    RouteResult|RouterError result = router.route({id: "   ", eventType: "app.event"});
    test:assertTrue(result is InvalidEventError, "expected an InvalidEventError");
    test:assertEquals(requestCount("ok"), 0);
}

@test:Config
function testDestinationNamesAreExposed() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       destinations: {audit: {url: MOCK_BASE_URL + "/mock/ok"}}
                                   });
    string[] expected = [DEFAULT_DESTINATION, "audit"];
    test:assertEquals(router.destinationNames().sort(), expected.sort());
}

// enableLogging is a public switch, so both branches need to work. There is no
// log assertion here; the point is that a silent router still routes.
@test:Config
function testLoggingCanBeDisabled() returns error? {
    Router router = check okRouter({
                                       destinationUrl: MOCK_BASE_URL + "/mock/ok",
                                       enableLogging: false
                                   });

    RouteResult delivered = check router.route({id: "evt-quiet", eventType: "app.event"});
    test:assertTrue(delivered.delivered);

    RouteResult|RouterError duplicate = router.route({id: "evt-quiet", eventType: "app.event"});
    test:assertTrue(duplicate is DuplicateEventError);
    test:assertEquals(requestCount("ok"), 1);
}
