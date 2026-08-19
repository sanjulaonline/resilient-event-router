// SoterCare API.
//
// The resource validates and classifies the sensor reading, then hands a
// domain-neutral event to the router. Duplicate suppression, the outbound
// timeout, transport retries, backoff and circuit breaking all live in
// sanjulaonline/resilient_event_router.

import ballerina/http;
import ballerina/log;

import sanjulaonline/resilient_event_router as router;

configurable int servicePort = 9090;
configurable string notifierBaseUrl = "http://localhost:9091";

final router:Router eventRouter = check new ({
    destinationUrl: notifierBaseUrl + "/notifier/alerts",
    routingRule: routeByCareDecision,
    timeout: 1,
    transportRetry: {count: 2, interval: 0.05, backOffFactor: 2.0, maxWaitInterval: 0.2},
    circuitBreaker: {
        timeWindow: 10,
        bucketSize: 2,
        requestVolumeThreshold: 10,
        failureThreshold: 0.5,
        resetTime: 2,
        statusCodes: [500, 502, 503]
    }
});

service /api/v1 on new http:Listener(servicePort) {

    isolated resource function get health() returns record {|string status; string serviceName;|} {
        return {status: "UP", serviceName: "sotercare-alert-router"};
    }

    isolated resource function post events(SensorEvent event)
            returns AcceptedResponse|ConflictResponse|BadRequestResponse|ServiceUnavailableResponse {
        string correlationId = event.eventId;

        CareDecision|error decision = validateAndClassify(event);
        if decision is error {
            BadRequestResponse response = {
                body: {code: "INVALID_EVENT", message: decision.message(), correlationId}
            };
            return response;
        }

        router:RouteResult|router:RouterError result =
            eventRouter.route(toRouterEvent(event, decision), toRouterSeverity(decision.severity));

        if result is router:DuplicateEventError {
            ConflictResponse response = {
                body: {
                    code: "DUPLICATE_EVENT",
                    message: "eventId has already been processed",
                    correlationId
                }
            };
            return response;
        }

        if result is router:RouterError {
            log:printError("caregiver notification failed", eventId = event.eventId,
                    deviceId = event.deviceId, failure = deliveryFailureKind(result),
                    reason = result.message());
            ServiceUnavailableResponse response = {
                body: {
                    code: "NOTIFIER_UNAVAILABLE",
                    message: "event was not marked as processed; retry with the same eventId",
                    correlationId
                }
            };
            return response;
        }

        log:printInfo("sensor event accepted", eventId = event.eventId, severity = decision.severity,
                routedTo = decision.routedTo, notified = result.delivered);
        AcceptedResponse response = {
            body: {
                eventId: event.eventId,
                status: "accepted",
                severity: decision.severity,
                routedTo: decision.routedTo,
                notified: result.delivered,
                correlationId
            }
        };
        return response;
    }
}

// The HTTP contract stays a single 503 so the published API does not change,
// but the typed router error is recorded so operators can tell the cases apart.
isolated function deliveryFailureKind(router:RouterError err) returns string {
    if err is router:CircuitOpenError {
        return "circuit-open";
    }
    if err is router:TransportError {
        return "transport";
    }
    if err is router:DownstreamError {
        return "downstream-status";
    }
    if err is router:InvalidDestinationError {
        return "invalid-destination";
    }
    return "unknown";
}
