// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

# Relative importance of an event.
#
# The router never derives severity by itself. It is either supplied by the
# caller or produced by a `Classifier`. Severity is used by routing rules, is
# included in the delivered envelope and in structured logs, and is echoed back
# in the `RouteResult`.
public enum Severity {
    # Routine event. Usually recorded rather than escalated.
    INFO,
    # Event that needs attention but is not urgent.
    WARNING,
    # Urgent event that should be delivered immediately.
    CRITICAL
}

# A domain-neutral event accepted by a `Router`.
#
# The package makes no assumption about what the event means. Application
# semantics (thresholds, validation, classification) stay in the calling
# application.
public type Event record {|
    # Caller-assigned identifier.
    #
    # This value is used as the idempotency key, so it must be stable across
    # retries of the same logical event and unique across distinct events.
    string id;
    # Event name, for example `order.created` or `temperature.alert`.
    #
    # Routing rules typically switch on this value.
    string eventType;
    # Event body forwarded to the destination inside the delivery envelope.
    #
    # This package never writes the payload to a log.
    json payload = ();
    # Small, non-sensitive key/value pairs forwarded inside the delivery
    # envelope. Intended for correlation ids, tenant ids, source names and
    # similar routing context. Metadata is not logged by default.
    map<string> metadata = {};
|};

# Outcome of a successful `Router.route` call.
public type RouteResult record {|
    # The `Event.id` that was routed.
    string eventId;
    # The `Event.eventType` that was routed.
    string eventType;
    # Severity that was supplied by the caller or produced by the classifier.
    Severity severity;
    # Name of the destination the event was delivered to, or `()` when the
    # routing rule suppressed delivery.
    string? destination;
    # `true` when the destination returned a 2xx response.
    #
    # `false` only when the routing rule suppressed delivery; a failed
    # delivery returns a `DeliveryError` instead of a result.
    boolean delivered;
    # Number of application-level delivery attempts made by the router.
    #
    # This is `1` unless `StatusRetryConfig` is enabled. Transport-level
    # retries performed inside `ballerina/http` happen within a single
    # application-level attempt and are not counted here.
    int attempts;
    # HTTP status code of the final response, or `()` when no request was sent.
    int? statusCode;
|};

# Derives a `Severity` from an event.
#
# Supplied through `RouterConfig.classifier` and used when `Router.route` is
# called without an explicit severity. Implementations must be `isolated` and
# must not block.
public type Classifier isolated function (Event event) returns Severity;

# Selects the destination for an event.
#
# Returns the name of a destination declared in `RouterConfig.destinations`, or
# `DEFAULT_DESTINATION` for the destination configured through
# `RouterConfig.destinationUrl`. Returning `()` suppresses delivery: the event
# is still recorded for idempotency and reported with `delivered: false`.
public type RoutingRule isolated function (Event event, Severity severity) returns string?;
