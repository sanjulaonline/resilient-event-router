// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/time;

// Result of one call to DeliveryTarget.deliver. Internal: callers see either a
// RouteResult or a DeliveryError.
type DeliveryOutcome record {|
    boolean delivered;
    int attempts;
    int? statusCode;
    DeliveryError? failure;
|};

// One configured HTTP destination together with its own resilient client.
// Circuit-breaker state is held per destination because it lives inside the
// underlying http:Client.
isolated class DeliveryTarget {
    private final string name;
    private final string path;
    private final http:Client httpClient;
    private final readonly & map<string> headers;
    private final readonly & StatusRetryConfig? statusRetry;

    isolated function init(TargetSpec spec) returns ConfigError? {
        [string, string] [origin, path] = splitUrl(spec.url.trim());
        self.name = spec.name;
        self.path = path;
        self.headers = spec.headers.cloneReadOnly();
        self.statusRetry = spec.statusRetry.cloneReadOnly();

        http:ClientConfiguration clientConfig = {
            timeout: spec.timeout,
            retryConfig: {
                interval: spec.transportRetry.interval,
                count: spec.transportRetry.count,
                backOffFactor: spec.transportRetry.backOffFactor,
                maxWaitInterval: spec.transportRetry.maxWaitInterval
            }
        };
        CircuitBreakerConfig? breaker = spec.circuitBreaker;
        if breaker is CircuitBreakerConfig {
            clientConfig.circuitBreaker = {
                rollingWindow: {
                    timeWindow: breaker.timeWindow,
                    bucketSize: breaker.bucketSize,
                    requestVolumeThreshold: breaker.requestVolumeThreshold
                },
                failureThreshold: breaker.failureThreshold,
                resetTime: breaker.resetTime,
                statusCodes: breaker.statusCodes
            };
        }

        http:Client|http:ClientError httpClient = new (origin, clientConfig);
        if httpClient is http:ClientError {
            return error ConfigError("could not create an HTTP client for destination '" + spec.name + "'",
                    httpClient, destination = spec.name);
        }
        self.httpClient = httpClient;
    }

    isolated function deliver(Event event, Severity severity) returns DeliveryOutcome {
        StatusRetryConfig? statusRetry = self.statusRetry;
        decimal startedAt = time:monotonicNow();
        decimal waitInterval = statusRetry is StatusRetryConfig ? statusRetry.interval : 0d;
        int attempts = 0;

        while true {
            attempts += 1;
            http:Response|http:ClientError response = self.send(event, severity);

            if response is http:ClientError {
                return {
                    delivered: false,
                    attempts,
                    statusCode: (),
                    failure: toDeliveryError(response, self.name, event.id, attempts)
                };
            }

            int statusCode = response.statusCode;
            if statusCode >= 200 && statusCode < 300 {
                return {delivered: true, attempts, statusCode, failure: ()};
            }

            if !(statusRetry is StatusRetryConfig)
                    || attempts > statusRetry.count
                    || statusRetry.statusCodes.indexOf(statusCode) is () {
                return {
                    delivered: false,
                    attempts,
                    statusCode,
                    failure: downstreamError(self.name, event.id, statusCode, attempts)
                };
            }

            decimal elapsed = time:monotonicNow() - startedAt;
            if elapsed + waitInterval >= statusRetry.maxElapsedTime {
                return {
                    delivered: false,
                    attempts,
                    statusCode,
                    failure: downstreamError(self.name, event.id, statusCode, attempts)
                };
            }

            runtime:sleep(waitInterval);
            decimal nextInterval = <decimal>(<float>waitInterval * statusRetry.backOffFactor);
            waitInterval = nextInterval > statusRetry.maxInterval ? statusRetry.maxInterval : nextInterval;
        }
    }

    isolated function send(Event event, Severity severity) returns http:Response|http:ClientError {
        http:Request request = new;
        request.setJsonPayload(deliveryEnvelope(event, severity));
        foreach [string, string] [name, value] in self.headers.entries() {
            request.setHeader(name, value);
        }
        request.setHeader(HEADER_EVENT_ID, event.id);
        request.setHeader(HEADER_EVENT_TYPE, event.eventType);
        request.setHeader(HEADER_EVENT_SEVERITY, severity);
        return self.httpClient->post(self.path, request);
    }
}

const string HEADER_EVENT_ID = "x-event-id";
const string HEADER_EVENT_TYPE = "x-event-type";
const string HEADER_EVENT_SEVERITY = "x-event-severity";

// Wire format POSTed to a destination. Documented in the package README.
isolated function deliveryEnvelope(Event event, Severity severity) returns json => {
    id: event.id,
    eventType: event.eventType,
    severity: severity,
    metadata: event.metadata.toJson(),
    payload: event.payload
};

// Splits an absolute URL into the origin used as the http:Client base URL and
// the request path. Keeping the path separate lets one client serve a
// destination whose URL contains a path or a query string.
isolated function splitUrl(string url) returns [string, string] {
    int schemeEnd = url.indexOf("://") is int ? <int>url.indexOf("://") + 3 : 0;
    int? slash = url.indexOf("/", schemeEnd);
    if slash is () {
        return [url, "/"];
    }
    return [url.substring(0, slash), url.substring(slash)];
}

isolated function downstreamError(string destination, string eventId, int statusCode, int attempts)
        returns DownstreamError =>
    error DownstreamError("destination '" + destination + "' returned HTTP " + statusCode.toString(),
            eventId = eventId, destination = destination, statusCode = statusCode, attempts = attempts);

// An http:ClientError means no usable HTTP response was produced. The only
// distinction the router draws is "the breaker refused to send" versus
// "the transport failed", because those need different operator responses.
// Everything else -- connection refused, DNS failure, reset, idle timeout,
// AllRetryAttemptsFailed -- is a TransportError.
isolated function toDeliveryError(http:ClientError err, string destination, string eventId, int attempts)
        returns DeliveryError {
    if isCircuitOpen(err) {
        return error CircuitOpenError("circuit breaker is open for destination '" + destination + "'",
                err, eventId = eventId, destination = destination, attempts = attempts);
    }
    return error TransportError("could not reach destination '" + destination + "': " + err.message(),
            err, eventId = eventId, destination = destination, attempts = attempts);
}

// ballerina/http 2.16.6 raises exactly this type when the breaker is open
// (resiliency_http_circuit_breaker.bal), and the breaker client wraps the retry
// client rather than the other way round, so the error is never re-wrapped by
// AllRetryAttemptsFailed. testCircuitOpenIsDetectedWithTransportRetryEnabled
// pins that ordering down.
isolated function isCircuitOpen(http:ClientError err) returns boolean =>
    err is http:UpstreamServiceUnavailableError;
