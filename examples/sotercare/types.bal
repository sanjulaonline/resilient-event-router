// HTTP contract of the SoterCare API and of the mock notifier.

import ballerina/http;

public type AcceptedBody readonly & record {|
    string eventId;
    string status;
    CareSeverity severity;
    string routedTo;
    boolean notified;
    string correlationId;
|};

public type ErrorBody readonly & record {|
    string code;
    string message;
    string correlationId;
|};

public type AcceptedResponse record {|
    *http:Accepted;
    AcceptedBody body;
|};

public type ConflictResponse record {|
    *http:Conflict;
    ErrorBody body;
|};

public type BadRequestResponse record {|
    *http:BadRequest;
    ErrorBody body;
|};

public type ServiceUnavailableResponse record {|
    *http:ServiceUnavailable;
    ErrorBody body;
|};

// Wire format produced by sanjulaonline/resilient_event_router. The mock notifier
// binds to it directly, which is also a check that the envelope is stable.
public type EventEnvelope record {|
    string id;
    string eventType;
    string severity;
    map<string> metadata;
    json payload;
|};

public type NotificationReceipt readonly & record {|
    string notificationId;
    string status;
    int attempt;
|};

public type NotifierAcceptedResponse record {|
    *http:Accepted;
    NotificationReceipt body;
|};

public type NotifierErrorResponse record {|
    *http:InternalServerError;
    ErrorBody body;
|};

public type AttemptCount readonly & record {|
    string eventId;
    int attempts;
|};
