// SoterCare domain layer.
//
// Everything in this file answers "what does this event mean?". Nothing here
// knows how the event is delivered; that is the job of the
// sanjulaonline/resilient_event_router package.

import sanjulaonline/resilient_event_router as router;

// Clinical-style severity used by the SoterCare API. It is intentionally finer
// grained than the router's transport severity, which is the point of keeping
// the two layers apart.
public type CareSeverity "normal"|"medium"|"high"|"critical";

// Named routes used by the SoterCare API and by the routing rule below.
public const string ROUTE_EVENT_LOG = "event-log";
public const string ROUTE_CAREGIVER = "caregiver-notifier";

public type SensorEvent readonly & record {|
    string eventId;
    string deviceId;
    string eventType;
    float value;
    string unit;
    int timestamp;
|};

public type CareDecision readonly & record {|
    CareSeverity severity;
    string routedTo;
    string reason;
|};

// Synthetic thresholds for a prototype. They have not been clinically
// reviewed and must not be used to detect, diagnose or treat anything.
public isolated function validateAndClassify(SensorEvent event) returns CareDecision|error {
    if event.eventId.length() < 4 {
        return error("eventId must contain at least four characters");
    }
    if event.deviceId.length() < 3 {
        return error("deviceId must contain at least three characters");
    }
    if event.timestamp <= 0 {
        return error("timestamp must be a positive Unix timestamp");
    }

    match event.eventType {
        "fall" => {
            if event.unit != "boolean" || (event.value != 0.0 && event.value != 1.0) {
                return error("fall events require unit 'boolean' and value 0.0 or 1.0");
            }
            if event.value == 1.0 {
                return {severity: "critical", routedTo: ROUTE_CAREGIVER, reason: "fall detected"};
            }
            return {severity: "normal", routedTo: ROUTE_EVENT_LOG, reason: "no fall detected"};
        }
        "vitals" => {
            if event.unit != "bpm" || event.value < 30.0 || event.value > 240.0 {
                return error("vitals events require unit 'bpm' and a value from 30.0 to 240.0");
            }
            if event.value < 50.0 || event.value > 120.0 {
                return {
                    severity: "high",
                    routedTo: ROUTE_CAREGIVER,
                    reason: "heart rate outside the prototype threshold"
                };
            }
            return {
                severity: "normal",
                routedTo: ROUTE_EVENT_LOG,
                reason: "heart rate inside the prototype threshold"
            };
        }
        "moisture" => {
            if event.unit != "percent" || event.value < 0.0 || event.value > 100.0 {
                return error("moisture events require unit 'percent' and a value from 0.0 to 100.0");
            }
            if event.value >= 80.0 {
                return {
                    severity: "medium",
                    routedTo: ROUTE_EVENT_LOG,
                    reason: "moisture crossed the prototype threshold"
                };
            }
            return {
                severity: "normal",
                routedTo: ROUTE_EVENT_LOG,
                reason: "moisture inside the prototype threshold"
            };
        }
        _ => {
            return error("unsupported eventType; use fall, vitals, or moisture");
        }
    }
}

// Maps the four SoterCare severities onto the three transport severities the
// router understands.
public isolated function toRouterSeverity(CareSeverity severity) returns router:Severity {
    match severity {
        "critical" => {
            return router:CRITICAL;
        }
        "high"|"medium" => {
            return router:WARNING;
        }
        _ => {
            return router:INFO;
        }
    }
}

// Builds the domain-neutral event handed to the router. The SoterCare routing
// choice travels as metadata so the routing rule stays a pure function of the
// generic event.
public isolated function toRouterEvent(SensorEvent event, CareDecision decision) returns router:Event => {
    id: event.eventId,
    eventType: "sensor." + event.eventType,
    payload: {
        deviceId: event.deviceId,
        value: event.value,
        unit: event.unit,
        timestamp: event.timestamp,
        reason: decision.reason
    },
    metadata: {
        route: decision.routedTo,
        careSeverity: decision.severity
    }
};

// Only caregiver-bound events leave the process. Everything else is recorded
// locally, which the router reports as delivered: false.
public isolated function routeByCareDecision(router:Event event, router:Severity severity) returns string? {
    string route = event.metadata["route"] ?: ROUTE_EVENT_LOG;
    return route == ROUTE_CAREGIVER ? router:DEFAULT_DESTINATION : ();
}
