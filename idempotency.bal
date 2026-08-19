// Copyright (c) 2026 Sanjula. Licensed under the Apache License, Version 2.0.

# Contract for duplicate-event detection.
#
# The router reserves an event id before it classifies or delivers an event and
# releases the reservation if delivery fails, so a failed delivery never
# permanently consumes an event id.
#
# Implementations must be safe to call concurrently. `reserve` must be atomic:
# for a given id exactly one concurrent caller may receive `true`. That
# requirement is what makes a durable store (for example Redis `SET NX` or a
# unique database key) a drop-in replacement for the bundled in-memory store.
public type IdempotencyStore isolated object {

    # Atomically records an event id if it is not already present.
    #
    # + eventId - Identifier to reserve
    # + return - `true` if the id was newly reserved, `false` if it was already
    # present, or an error if the store could not be reached
    public isolated function reserve(string eventId) returns boolean|error;

    # Removes a reservation so the same id can be routed again.
    #
    # Called by the router when delivery fails. Removing an id that is not
    # present must not be an error.
    #
    # + eventId - Identifier to release
    # + return - An error if the store could not be reached
    public isolated function release(string eventId) returns error?;

    # Reports whether an event id is currently reserved.
    #
    # + eventId - Identifier to look up
    # + return - `true` if the id is present, or an error if the store could
    # not be reached
    public isolated function contains(string eventId) returns boolean|error;
};

# Process-local, non-durable `IdempotencyStore` used when
# `RouterConfig.idempotencyStore` is not set.
#
# Reservations live in a map inside the current process. They are lost on
# restart and are not shared between replicas, so two instances of the same
# service will each accept the same event id once. Use a durable store for
# multi-instance deployments.
#
# The map grows for the lifetime of the process; there is no eviction. Call
# `clear` from tests, or supply a bounded custom store for long-running
# high-volume services.
public isolated class InMemoryIdempotencyStore {
    *IdempotencyStore;

    private final map<boolean> reserved = {};

    # Atomically records an event id if it is not already present.
    #
    # + eventId - Identifier to reserve
    # + return - `true` if the id was newly reserved, `false` otherwise
    public isolated function reserve(string eventId) returns boolean|error {
        lock {
            if self.reserved.hasKey(eventId) {
                return false;
            }
            self.reserved[eventId] = true;
            return true;
        }
    }

    # Removes a reservation so the same id can be routed again.
    #
    # + eventId - Identifier to release
    # + return - `()`; this store never fails
    public isolated function release(string eventId) returns error? {
        lock {
            _ = self.reserved.removeIfHasKey(eventId);
        }
        return;
    }

    # Reports whether an event id is currently reserved.
    #
    # + eventId - Identifier to look up
    # + return - `true` if the id is present
    public isolated function contains(string eventId) returns boolean|error {
        lock {
            return self.reserved.hasKey(eventId);
        }
    }

    # Number of reserved event ids currently held.
    #
    # + return - The reservation count
    public isolated function size() returns int {
        lock {
            return self.reserved.length();
        }
    }

    # Removes every reservation. Intended for tests and for resetting a
    # long-running process.
    public isolated function clear() {
        lock {
            self.reserved.removeAll();
        }
    }
}
