import ballerina/http;
import ballerina/test;

final http:Client apiClient = check new ("http://localhost:9090");
final http:Client mockClient = check new ("http://localhost:9091");

@test:BeforeEach
function resetState() {
    resetPrototypeState();
}

@test:Config
function testHealthEndpoint() returns error? {
    http:Response response = check apiClient->get("/api/v1/health");
    test:assertEquals(response.statusCode, 200);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.status, "UP");
}

@test:Config
function testNormalVitalsAcceptedLocally() returns error? {
    SensorEvent event = sampleEvent("normal-vitals-001", "vitals", 72.0, "bpm");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 202);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.severity, "normal");
    test:assertEquals(payload.routedTo, "event-log");
    test:assertEquals(payload.notified, false);
    test:assertEquals(getNotifierAttempts("normal-vitals-001"), 0);
}

@test:Config
function testCriticalFallRoutedToNotifier() returns error? {
    SensorEvent event = sampleEvent("critical-fall-001", "fall", 1.0, "boolean");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 202);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.severity, "critical");
    test:assertEquals(payload.routedTo, "caregiver-notifier");
    test:assertEquals(payload.notified, true);
    test:assertEquals(getNotifierAttempts("critical-fall-001"), 1);
}

@test:Config
function testHighHeartRateRoutedToNotifier() returns error? {
    SensorEvent event = sampleEvent("high-vitals-001", "vitals", 150.0, "bpm");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 202);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.severity, "high");
    test:assertEquals(payload.routedTo, "caregiver-notifier");
}

@test:Config
function testUnsupportedEventRejected() returns error? {
    SensorEvent event = sampleEvent("unsupported-001", "temperature", 38.0, "celsius");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 400);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.code, "INVALID_EVENT");
}

@test:Config
function testInvalidRangeRejected() returns error? {
    SensorEvent event = sampleEvent("bad-range-001", "vitals", 500.0, "bpm");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 400);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.code, "INVALID_EVENT");
}

@test:Config
function testDuplicateEventRejected() returns error? {
    SensorEvent event = sampleEvent("duplicate-001", "moisture", 85.0, "percent");
    http:Response first = check apiClient->post("/api/v1/events", event);
    http:Response second = check apiClient->post("/api/v1/events", event);
    test:assertEquals(first.statusCode, 202);
    test:assertEquals(second.statusCode, 409);
    json payload = check second.getJsonPayload();
    test:assertEquals(payload.code, "DUPLICATE_EVENT");
}

@test:Config
function testMalformedJsonRejectedByDataBinding() returns error? {
    http:Request request = new;
    request.setHeader("content-type", "application/json");
    request.setTextPayload("{not-valid-json");
    http:Response response = check apiClient->post("/api/v1/events", request);
    test:assertEquals(response.statusCode, 400);
}

// Preserved from the original project. Ballerina's transport retry covers
// network failures, not HTTP 500 responses, so the notifier sees one attempt.
@test:Config
function testHttpFiveHundredIsNotRetried() returns error? {
    SensorEvent event = sampleEvent("fail-status-001", "fall", 1.0, "boolean");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 503);

    http:Response attemptsResponse = check mockClient->get("/notifier/attempts/fail-status-001");
    json payload = check attemptsResponse.getJsonPayload();
    test:assertEquals(payload.attempts, 1);
}

@test:Config
function testPermanentNotifierFailureIsControlled() returns error? {
    SensorEvent event = sampleEvent("fail-fall-001", "fall", 1.0, "boolean");
    http:Response response = check apiClient->post("/api/v1/events", event);
    test:assertEquals(response.statusCode, 503);
    json payload = check response.getJsonPayload();
    test:assertEquals(payload.code, "NOTIFIER_UNAVAILABLE");
    // The router released the event id, so the caller may retry with it.
    test:assertFalse(check eventRouter.isRouted(event.eventId));
}

@test:Config
function testDomainClassificationIsIndependentOfTransport() returns error? {
    CareDecision fall = check validateAndClassify(sampleEvent("unit-fall-001", "fall", 1.0, "boolean"));
    test:assertEquals(fall.severity, "critical");
    test:assertEquals(toRouterSeverity(fall.severity), "CRITICAL");

    CareDecision moisture = check validateAndClassify(sampleEvent("unit-moist-001", "moisture", 90.0, "percent"));
    test:assertEquals(moisture.severity, "medium");
    test:assertEquals(moisture.routedTo, "event-log");
    test:assertEquals(toRouterSeverity(moisture.severity), "WARNING");
    // A WARNING that the domain wants logged locally is still not delivered.
    test:assertEquals(routeByCareDecision(toRouterEvent(
                            sampleEvent("unit-moist-001", "moisture", 90.0, "percent"), moisture), "WARNING"), ());
}

function sampleEvent(string eventId, string eventType, float value, string unit) returns SensorEvent {
    return {
        eventId,
        deviceId: "esp32-bedroom-01",
        eventType,
        value,
        unit,
        timestamp: 1786780800
    };
}
