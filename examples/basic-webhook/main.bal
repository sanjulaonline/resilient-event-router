// Smallest useful consumer of sanjulaonline/resilient_event_router: send an
// application event to an HTTP webhook and handle the typed outcome.
//
//   bal run -- -CwebhookUrl=http://localhost:8290/hook

import ballerina/io;

import sanjulaonline/resilient_event_router as router;

configurable string webhookUrl = "http://localhost:8290/hook";

public function main() returns error? {
    router:Router eventRouter = check new ({destinationUrl: webhookUrl});

    router:Event event = {
        id: "order-123",
        eventType: "order.created",
        payload: {orderId: "123", amount: 145.50},
        metadata: {origin: "checkout-api"}
    };

    router:RouteResult|router:RouterError result = eventRouter.route(event, router:WARNING);

    if result is router:DuplicateEventError {
        io:println("already routed: ", result.detail()?.eventId ?: "");
        return;
    }
    if result is router:CircuitOpenError {
        io:println("circuit is open; back off before sending more events");
        return;
    }
    if result is router:DownstreamError {
        io:println("webhook rejected the event with HTTP ", result.detail()?.statusCode ?: 0);
        return;
    }
    if result is router:RouterError {
        io:println("could not deliver the event: ", result.message());
        return;
    }

    io:println("delivered ", result.eventId, " to ", result.destination ?: "-",
            " (status ", result.statusCode ?: 0, ", attempts ", result.attempts, ")");
}
