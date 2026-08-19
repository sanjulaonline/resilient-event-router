// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

# Context attached to every `RouterError`.
public type ErrorDetail record {|
    # Identifier of the event that produced the error, when known.
    string eventId?;
    # Name of the destination involved, when known.
    string destination?;
    # HTTP status code returned by the destination, when a response was
    # received. Absent for configuration and transport errors.
    int statusCode?;
    # Number of application-level delivery attempts that were made.
    int attempts?;
|};

# Base type of every error returned by this package.
#
# Callers that do not need to distinguish outcomes can match on this type
# alone; all other error types in the package are subtypes of it.
public type RouterError distinct error<ErrorDetail>;

# The router configuration is not usable.
#
# Returned by `Router.init` for an empty or non-HTTP destination URL, a
# non-positive timeout, or an out-of-range retry or circuit-breaker setting.
public type ConfigError distinct RouterError;

# The event id has already been reserved by the idempotency store.
#
# The event was neither classified nor delivered. This is an expected outcome,
# not a fault; callers typically map it to HTTP `409 Conflict`.
public type DuplicateEventError distinct RouterError;

# The event cannot be routed because it is structurally unusable.
#
# Returned when `Event.id` is empty; an empty id cannot act as an idempotency
# key. Domain validation stays with the calling application.
public type InvalidEventError distinct RouterError;

# The routing rule named a destination that is not configured.
public type InvalidDestinationError distinct RouterError;

# The idempotency store itself failed.
#
# Only reachable with a custom `IdempotencyStore`; the bundled in-memory store
# never fails.
public type IdempotencyStoreError distinct RouterError;

# Base type for every failure to deliver an event.
#
# The event id is released before this error is returned, so the same event may
# be routed again with the same id.
public type DeliveryError distinct RouterError;

# The request never produced an HTTP response.
#
# Covers connection refused, DNS failure, idle timeout and connection resets.
# These are the failures that `RetryConfig` retries inside `ballerina/http`.
public type TransportError distinct DeliveryError;

# The circuit breaker for the destination is open and the request was not sent.
public type CircuitOpenError distinct DeliveryError;

# The destination returned a non-2xx HTTP response.
#
# This is an application-level rejection, not a transport failure. It is never
# retried by `RetryConfig`; use `StatusRetryConfig` to retry selected status
# codes explicitly. `ErrorDetail.statusCode` carries the returned status.
public type DownstreamError distinct DeliveryError;
