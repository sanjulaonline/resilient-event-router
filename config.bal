// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

# Name of the destination created from `RouterConfig.destinationUrl`.
#
# A routing rule that returns this name, and the default routing rule, both
# resolve to that destination.
public const string DEFAULT_DESTINATION = "default";

// Defaults for RouterConfig. Not exported: the effective values are documented
// on the fields that use them, so a consumer never needs to name them.
const decimal DEFAULT_TIMEOUT = 1;
const int DEFAULT_RETRY_COUNT = 2;

# An HTTP destination an event can be delivered to.
public type DestinationConfig record {|
    # Absolute `http` or `https` URL the event envelope is POSTed to.
    string url;
    # Headers added to every request sent to this destination. Merged over
    # `RouterConfig.headers`, so a value here wins on conflict.
    map<string> headers = {};
|};

# Transport-level retry policy, applied by `ballerina/http`.
#
# This policy retries failures that never produced an HTTP response:
# connection refused, DNS failure, connection reset and idle timeout. It does
# **not** retry HTTP error responses such as `500`; use `StatusRetryConfig` for
# that. See the "Retry behaviour" section of the package README.
public type TransportRetryConfig record {|
    # Number of retries after the initial attempt. `0` disables retrying.
    int count = DEFAULT_RETRY_COUNT;
    # Delay in seconds before the first retry.
    decimal interval = 0.05;
    # Multiplier applied to the delay after each retry.
    float backOffFactor = 2.0;
    # Upper bound in seconds for a single retry delay.
    decimal maxWaitInterval = 0.2;
|};

# Circuit-breaker policy, applied by `ballerina/http` per destination.
#
# While the circuit is open the client fails fast and the router returns a
# `CircuitOpenError` without sending a request.
public type CircuitBreakerConfig record {|
    # Length in seconds of the rolling window used to compute the failure ratio.
    decimal timeWindow = 10;
    # Length in seconds of one bucket inside the rolling window.
    decimal bucketSize = 2;
    # Minimum number of requests in the window before the breaker can trip.
    int requestVolumeThreshold = 10;
    # Failure ratio, in `(0, 1]`, that trips the breaker.
    float failureThreshold = 0.5;
    # Seconds the breaker stays open before allowing a trial request.
    decimal resetTime = 2;
    # HTTP status codes counted as failures by the breaker.
    int[] statusCodes = [500, 502, 503, 504];
|};

# Application-level retry policy for selected HTTP status codes.
#
# Disabled by default and deliberately separate from `TransportRetryConfig`: retrying an
# HTTP response means the destination received and processed the request, so
# the destination must be idempotent for the retried event id. Both the number
# of attempts and the total elapsed time are bounded.
public type StatusRetryConfig record {|
    # Status codes that are retried. Codes outside this set fail immediately.
    int[] statusCodes = [502, 503, 504];
    # Number of retries after the initial attempt. `0` disables retrying.
    int count = 2;
    # Delay in seconds before the first retry.
    decimal interval = 0.2;
    # Multiplier applied to the delay after each retry.
    float backOffFactor = 2.0;
    # Upper bound in seconds for a single retry delay.
    decimal maxInterval = 2;
    # Upper bound in seconds for the whole delivery, including the initial
    # attempt. No further retry starts once this budget is spent.
    decimal maxElapsedTime = 5;
|};

# Configuration for a `Router`.
#
# Every field except `destinationUrl` has a default, so the smallest useful
# configuration is `{destinationUrl: "https://example.com/webhook"}`.
public type RouterConfig record {|
    # Absolute `http` or `https` URL of the default destination.
    string destinationUrl;
    # Additional named destinations that a `RoutingRule` may select. The key is
    # the destination name used by the rule. `DEFAULT_DESTINATION` is reserved.
    map<DestinationConfig> destinations = {};
    # Headers added to every outbound request, for every destination.
    map<string> headers = {};
    # Request timeout in seconds. Must be greater than zero.
    decimal timeout = DEFAULT_TIMEOUT;
    # Transport-level retry policy.
    TransportRetryConfig transportRetry = {};
    # Circuit-breaker policy. Set to `()` to disable circuit breaking.
    CircuitBreakerConfig? circuitBreaker = {};
    # Application-level retry policy for HTTP status codes. Disabled by
    # default; see `StatusRetryConfig` before enabling it.
    StatusRetryConfig? statusRetry = ();
    # Idempotency store. Defaults to a process-local `InMemoryIdempotencyStore`.
    IdempotencyStore? idempotencyStore = ();
    # Derives severity when `Router.route` is called without one. Defaults to
    # `INFO`.
    Classifier? classifier = ();
    # Selects the destination for an event. Defaults to sending every event to
    # `DEFAULT_DESTINATION`.
    RoutingRule? routingRule = ();
    # Emit an `info` log line per routed event and an `error` line per failed
    # delivery. Payloads and metadata are never logged.
    boolean enableLogging = true;
|};

isolated function validateConfig(RouterConfig config) returns ConfigError? {
    check validateUrl(config.destinationUrl, DEFAULT_DESTINATION);
    foreach [string, DestinationConfig] [name, destination] in config.destinations.entries() {
        if name.trim().length() == 0 {
            return error ConfigError("destination name must not be empty");
        }
        if name == DEFAULT_DESTINATION {
            return error ConfigError("destination name '" + DEFAULT_DESTINATION
                    + "' is reserved for destinationUrl");
        }
        check validateUrl(destination.url, name);
    }

    if config.timeout <= 0d {
        return error ConfigError("timeout must be greater than zero");
    }

    TransportRetryConfig transportRetry = config.transportRetry;
    if transportRetry.count < 0 {
        return error ConfigError("transportRetry.count must not be negative");
    }
    if transportRetry.interval < 0d {
        return error ConfigError("transportRetry.interval must not be negative");
    }
    if transportRetry.backOffFactor < 1.0 {
        return error ConfigError("transportRetry.backOffFactor must be at least 1.0");
    }
    if transportRetry.maxWaitInterval < transportRetry.interval {
        return error ConfigError("transportRetry.maxWaitInterval must not be smaller than transportRetry.interval");
    }

    CircuitBreakerConfig? breaker = config.circuitBreaker;
    if breaker is CircuitBreakerConfig {
        if breaker.timeWindow <= 0d || breaker.bucketSize <= 0d {
            return error ConfigError("circuitBreaker.timeWindow and bucketSize must be greater than zero");
        }
        if breaker.bucketSize > breaker.timeWindow {
            return error ConfigError("circuitBreaker.bucketSize must not exceed circuitBreaker.timeWindow");
        }
        if breaker.failureThreshold <= 0.0 || breaker.failureThreshold > 1.0 {
            return error ConfigError("circuitBreaker.failureThreshold must be in (0, 1]");
        }
        if breaker.requestVolumeThreshold < 1 {
            return error ConfigError("circuitBreaker.requestVolumeThreshold must be at least 1");
        }
        if breaker.resetTime <= 0d {
            return error ConfigError("circuitBreaker.resetTime must be greater than zero");
        }
    }

    StatusRetryConfig? statusRetry = config.statusRetry;
    if statusRetry is StatusRetryConfig {
        if statusRetry.count < 0 {
            return error ConfigError("statusRetry.count must not be negative");
        }
        if statusRetry.statusCodes.length() == 0 && statusRetry.count > 0 {
            return error ConfigError("statusRetry.statusCodes must not be empty when statusRetry.count is positive");
        }
        if statusRetry.interval < 0d {
            return error ConfigError("statusRetry.interval must not be negative");
        }
        if statusRetry.backOffFactor < 1.0 {
            return error ConfigError("statusRetry.backOffFactor must be at least 1.0");
        }
        if statusRetry.maxInterval < statusRetry.interval {
            return error ConfigError("statusRetry.maxInterval must not be smaller than statusRetry.interval");
        }
        if statusRetry.maxElapsedTime <= 0d {
            return error ConfigError("statusRetry.maxElapsedTime must be greater than zero");
        }
    }
    return;
}

isolated function validateUrl(string url, string name) returns ConfigError? {
    string trimmed = url.trim();
    if trimmed.length() == 0 {
        return error ConfigError("destination '" + name + "' must declare a URL", destination = name);
    }
    if !trimmed.startsWith("http://") && !trimmed.startsWith("https://") {
        return error ConfigError("destination '" + name + "' must use an http or https URL", destination = name);
    }
    return;
}
