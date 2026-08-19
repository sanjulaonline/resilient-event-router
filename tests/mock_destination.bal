// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.
//
// Deterministic destinations used by the package tests. Every failure mode is
// produced locally so no test depends on network conditions or timing luck.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/tcp;

const int MOCK_HTTP_PORT = 18081;
const int MOCK_TCP_PORT = 18099;
const string MOCK_BASE_URL = "http://localhost:18081";
// Nothing listens here; used for connection-refused tests.
const string UNREACHABLE_URL = "http://localhost:18098/none";
// Accepts the TCP connection and closes it without writing an HTTP response.
const string CLOSING_URL = "http://localhost:18099/close";

isolated map<int> requestCounts = {};
isolated map<int> flakyFailures = {};
isolated map<json> lastEnvelopes = {};
isolated map<map<string>> lastHeaders = {};

isolated function countRequest(string key) returns int {
    lock {
        int next = (requestCounts[key] ?: 0) + 1;
        requestCounts[key] = next;
        return next;
    }
}

isolated function requestCount(string key) returns int {
    lock {
        return requestCounts[key] ?: 0;
    }
}

isolated function resetMockState() {
    lock {
        requestCounts.removeAll();
    }
    lock {
        flakyFailures.removeAll();
    }
    lock {
        lastEnvelopes.removeAll();
    }
    lock {
        lastHeaders.removeAll();
    }
}

isolated function headerOrDefault(http:Request request, string name, string fallback) returns string {
    string|http:HeaderNotFoundError value = request.getHeader(name);
    return value is string ? value : fallback;
}

isolated function recordRequest(http:Request request, json envelope) {
    string eventId = headerOrDefault(request, "x-event-id", "unknown");
    lock {
        lastEnvelopes[eventId] = envelope.clone();
    }
    map<string> headers = {};
    foreach string name in request.getHeaderNames() {
        string|http:HeaderNotFoundError value = request.getHeader(name);
        if value is string {
            headers[name.toLowerAscii()] = value;
        }
    }
    lock {
        lastHeaders[eventId] = headers.clone();
    }
}

isolated function envelopeFor(string eventId) returns json {
    lock {
        return (lastEnvelopes[eventId] ?: ()).clone();
    }
}

isolated function headersFor(string eventId) returns map<string> {
    lock {
        return (lastHeaders[eventId] ?: {}).clone();
    }
}

// Remaining forced failures for a flaky event id, seeded on first contact.
isolated function nextFlakyStatus(string eventId, int failuresBeforeSuccess) returns int {
    lock {
        int remaining = flakyFailures[eventId] ?: failuresBeforeSuccess;
        if remaining <= 0 {
            flakyFailures[eventId] = 0;
            return 202;
        }
        flakyFailures[eventId] = remaining - 1;
        return 503;
    }
}

service /mock on new http:Listener(MOCK_HTTP_PORT) {

    isolated resource function post ok(http:Request request, @http:Payload json envelope)
            returns http:Accepted {
        _ = countRequest("ok");
        recordRequest(request, envelope);
        return {body: {status: "accepted"}};
    }

    isolated resource function post fail500(http:Request request, @http:Payload json envelope)
            returns http:InternalServerError {
        _ = countRequest("fail500");
        recordRequest(request, envelope);
        return {body: {status: "boom"}};
    }

    isolated resource function post fail400(http:Request request, @http:Payload json envelope)
            returns http:BadRequest {
        _ = countRequest("fail400");
        recordRequest(request, envelope);
        return {body: {status: "rejected"}};
    }

    // Fails twice with 503 for each event id, then accepts.
    isolated resource function post flaky(http:Request request, @http:Payload json envelope)
            returns http:Accepted|http:ServiceUnavailable {
        _ = countRequest("flaky");
        recordRequest(request, envelope);
        string eventId = headerOrDefault(request, "x-event-id", "unknown");
        if nextFlakyStatus(eventId, 2) == 202 {
            return <http:Accepted>{body: {status: "accepted"}};
        }
        return <http:ServiceUnavailable>{body: {status: "unavailable"}};
    }

    isolated resource function post slow(http:Request request, @http:Payload json envelope)
            returns http:Accepted {
        _ = countRequest("slow");
        recordRequest(request, envelope);
        runtime:sleep(1.5);
        return {body: {status: "accepted"}};
    }

    isolated resource function get counts/[string key]() returns int => requestCount(key);
}

// Counts TCP connections and closes each one without an HTTP response, which
// is a transport failure rather than an HTTP error response.
service on new tcp:Listener(MOCK_TCP_PORT) {
    isolated remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        _ = countRequest("tcp");
        return new ClosingConnectionService();
    }
}

isolated service class ClosingConnectionService {
    *tcp:ConnectionService;

    isolated remote function onBytes(tcp:Caller caller, readonly & byte[] data) returns tcp:Error? {
        return caller->close();
    }
}
