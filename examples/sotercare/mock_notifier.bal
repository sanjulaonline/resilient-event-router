// Deliberately unreliable downstream notifier.
//
// It is part of the example so the failure paths are reproducible without an
// external account or real data. Event ids beginning with "fail-" always
// return HTTP 500.

import ballerina/http;

configurable int notifierPort = 9091;

isolated map<int> notifierAttempts = {};

isolated function nextNotifierAttempt(string eventId) returns int {
    lock {
        int next = (notifierAttempts[eventId] ?: 0) + 1;
        notifierAttempts[eventId] = next;
        return next;
    }
}

public isolated function getNotifierAttempts(string eventId) returns int {
    lock {
        return notifierAttempts[eventId] ?: 0;
    }
}

public isolated function resetPrototypeState() {
    lock {
        notifierAttempts.removeAll();
    }
}

service /notifier on new http:Listener(notifierPort) {

    isolated resource function post alerts(EventEnvelope envelope)
            returns NotifierAcceptedResponse|NotifierErrorResponse {
        int attempt = nextNotifierAttempt(envelope.id);

        if envelope.id.startsWith("fail-") {
            NotifierErrorResponse failure = {
                body: {
                    code: "SIMULATED_NOTIFIER_FAILURE",
                    message: "synthetic downstream failure",
                    correlationId: envelope.id
                }
            };
            return failure;
        }

        NotifierAcceptedResponse accepted = {
            body: {
                notificationId: "notification-" + envelope.id,
                status: "delivered",
                attempt
            }
        };
        return accepted;
    }

    isolated resource function get attempts/[string eventId]() returns AttemptCount {
        return {eventId, attempts: getNotifierAttempts(eventId)};
    }
}
