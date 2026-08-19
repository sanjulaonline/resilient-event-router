// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

import ballerina/log;

// Flattened, per-destination view of RouterConfig. Internal.
type TargetSpec record {|
    string name;
    string url;
    map<string> headers;
    decimal timeout;
    TransportRetryConfig transportRetry;
    CircuitBreakerConfig? circuitBreaker;
    StatusRetryConfig? statusRetry;
|};

// Holds the configured destinations. A separate isolated object keeps the
// mutable map out of Router and lets Router expose isolated methods.
isolated class TargetRegistry {
    private final map<DeliveryTarget> targets = {};

    isolated function add(string name, DeliveryTarget target) {
        lock {
            self.targets[name] = target;
        }
    }

    isolated function get(string name) returns DeliveryTarget? {
        lock {
            return self.targets[name];
        }
    }

    isolated function names() returns string[] {
        lock {
            return self.targets.keys().clone();
        }
    }
}

# Routes events to HTTP destinations with duplicate suppression, a request
# timeout, transport-level retries, exponential backoff and circuit breaking.
#
# A `Router` is safe to share across workers and services. Create one per set
# of destinations and keep it for the lifetime of the process; each destination
# owns an HTTP client whose circuit-breaker state is per destination.
#
# ```ballerina
# final Router eventRouter = check new ({destinationUrl: "https://example.com/webhook"});
# RouteResult result = check eventRouter.route({id: "order-123", eventType: "order.created"}, WARNING);
# ```
public isolated class Router {
    private final TargetRegistry registry;
    private final IdempotencyStore store;
    private final Classifier? classifier;
    private final RoutingRule? routingRule;
    private final boolean enableLogging;

    # Creates a router and its per-destination HTTP clients.
    #
    # + config - Destinations and resilience settings. Only
    # `RouterConfig.destinationUrl` is required.
    # + return - A `ConfigError` if a URL is missing or not an `http`/`https`
    # URL, if a destination name collides with `DEFAULT_DESTINATION`, if the
    # timeout is not positive, if a retry or circuit-breaker value is out of
    # range, or if an HTTP client could not be created
    public isolated function init(RouterConfig config) returns ConfigError? {
        check validateConfig(config);

        self.classifier = config.classifier;
        self.routingRule = config.routingRule;
        self.enableLogging = config.enableLogging;

        IdempotencyStore? configured = config.idempotencyStore;
        self.store = configured is IdempotencyStore ? configured : new InMemoryIdempotencyStore();

        self.registry = new TargetRegistry();
        foreach TargetSpec spec in targetSpecs(config) {
            DeliveryTarget|ConfigError target = new (spec);
            if target is ConfigError {
                return target;
            }
            self.registry.add(spec.name, target);
        }
    }

    # Reserves the event id, classifies the event, selects a destination and
    # delivers the event.
    #
    # The event id is reserved in the idempotency store before anything else
    # happens and is released again if delivery fails, so a failed delivery
    # never permanently consumes an event id.
    #
    # + event - The event to route. Its `id` is the idempotency key
    # + severity - Severity to use. When omitted, `RouterConfig.classifier`
    # decides; without a classifier the severity is `INFO`
    # + return - A `RouteResult` on success, or one of:
    # `InvalidEventError` for an empty event id;
    # `DuplicateEventError` when the id is already reserved;
    # `InvalidDestinationError` when the routing rule names an unknown
    # destination;
    # `CircuitOpenError` when the breaker for the destination is open;
    # `TransportError` when no HTTP response was produced;
    # `DownstreamError` when the destination returned a non-2xx status;
    # `IdempotencyStoreError` when a custom store failed
    public isolated function route(Event event, Severity? severity = ()) returns RouteResult|RouterError {
        string eventId = event.id;
        if eventId.trim().length() == 0 {
            return error InvalidEventError("event.id must not be empty");
        }

        Severity resolved = severity ?: self.classify(event);

        boolean|error reserved = self.store.reserve(eventId);
        if reserved is error {
            return error IdempotencyStoreError("idempotency store failed to reserve the event id",
                    reserved, eventId = eventId);
        }
        if !reserved {
            return error DuplicateEventError("event id has already been routed", eventId = eventId);
        }

        string? destination = self.selectDestination(event, resolved);
        if destination is () {
            RouteResult result = {
                eventId,
                eventType: event.eventType,
                severity: resolved,
                destination: (),
                delivered: false,
                attempts: 0,
                statusCode: ()
            };
            self.logRouted(result);
            return result;
        }

        DeliveryTarget? target = self.registry.get(destination);
        if target is () {
            self.release(eventId);
            return error InvalidDestinationError("no destination named '" + destination + "' is configured",
                    eventId = eventId, destination = destination);
        }

        DeliveryOutcome outcome = target.deliver(event, resolved);
        DeliveryError? failure = outcome.failure;
        if failure is DeliveryError {
            self.release(eventId);
            if self.enableLogging {
                // The message and kind are logged, not the error value, so a
                // failed delivery does not dump a stack trace per event. The
                // caller receives the typed error and can log more if needed.
                log:printError("event delivery failed", eventId = eventId, eventType = event.eventType,
                        severity = resolved, destination = destination, attempts = outcome.attempts,
                        statusCode = outcome.statusCode, failure = failureKind(failure),
                        reason = failure.message());
            }
            return failure;
        }

        RouteResult result = {
            eventId,
            eventType: event.eventType,
            severity: resolved,
            destination,
            delivered: outcome.delivered,
            attempts: outcome.attempts,
            statusCode: outcome.statusCode
        };
        self.logRouted(result);
        return result;
    }

    # Reports whether an event id is currently held by the idempotency store.
    #
    # + eventId - Identifier to look up
    # + return - `true` if a later `route` call with the same id would be
    # rejected as a duplicate, or an `IdempotencyStoreError` if the store failed
    public isolated function isRouted(string eventId) returns boolean|RouterError {
        boolean|error present = self.store.contains(eventId);
        if present is error {
            return error IdempotencyStoreError("idempotency store lookup failed", present, eventId = eventId);
        }
        return present;
    }

    # Removes an event id from the idempotency store so it can be routed again.
    #
    # Intended for replays and for tests. Removing an id that is not present is
    # not an error.
    #
    # + eventId - Identifier to release
    # + return - An `IdempotencyStoreError` if the store failed
    public isolated function forget(string eventId) returns RouterError? {
        error? err = self.store.release(eventId);
        if err is error {
            return error IdempotencyStoreError("idempotency store release failed", err, eventId = eventId);
        }
        return;
    }

    // Configured destination names. Module-private: a routing rule author
    // already knows the names they configured, so this is only used by tests.
    isolated function destinationNames() returns string[] => self.registry.names();

    private isolated function classify(Event event) returns Severity {
        Classifier? classifier = self.classifier;
        return classifier is Classifier ? classifier(event) : INFO;
    }

    private isolated function selectDestination(Event event, Severity severity) returns string? {
        RoutingRule? rule = self.routingRule;
        return rule is RoutingRule ? rule(event, severity) : DEFAULT_DESTINATION;
    }

    private isolated function release(string eventId) {
        error? err = self.store.release(eventId);
        if err is error && self.enableLogging {
            log:printError("could not release the reserved event id", eventId = eventId,
                    reason = err.message());
        }
    }

    private isolated function logRouted(RouteResult result) {
        if !self.enableLogging {
            return;
        }
        log:printInfo("event routed", eventId = result.eventId, eventType = result.eventType,
                severity = result.severity, destination = result.destination, delivered = result.delivered,
                attempts = result.attempts, statusCode = result.statusCode);
    }
}

// Stable, low-cardinality label for a delivery failure, safe for logs and
// metrics.
isolated function failureKind(DeliveryError failure) returns string {
    if failure is CircuitOpenError {
        return "circuit-open";
    }
    if failure is TransportError {
        return "transport";
    }
    return "downstream-status";
}

isolated function targetSpecs(RouterConfig config) returns TargetSpec[] {
    TargetSpec[] specs = [
        {
            name: DEFAULT_DESTINATION,
            url: config.destinationUrl,
            headers: mergeHeaders(config.headers, {}),
            timeout: config.timeout,
            transportRetry: config.transportRetry,
            circuitBreaker: config.circuitBreaker,
            statusRetry: config.statusRetry
        }
    ];
    foreach [string, DestinationConfig] [name, destination] in config.destinations.entries() {
        specs.push({
            name,
            url: destination.url,
            headers: mergeHeaders(config.headers, destination.headers),
            timeout: config.timeout,
            transportRetry: config.transportRetry,
            circuitBreaker: config.circuitBreaker,
            statusRetry: config.statusRetry
        });
    }
    return specs;
}

isolated function mergeHeaders(map<string> base, map<string> override) returns map<string> {
    map<string> merged = base.clone();
    foreach [string, string] [name, value] in override.entries() {
        merged[name] = value;
    }
    return merged;
}
