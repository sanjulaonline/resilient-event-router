// Consumer test.
//
// This package depends on sanjula/resilient_event_router the same way any
// other application would: through the published package, using only its
// public API. Nothing here reaches into the library's internals.

import ballerina/http;
import ballerina/test;

import sanjula/resilient_event_router as router;

const int RECEIVER_PORT = 8290;
const string RECEIVER_URL = "http://localhost:8290/hook";

isolated int received = 0;
isolated json lastEnvelope = ();

service /hook on new http:Listener(RECEIVER_PORT) {
    isolated resource function post .(@http:Payload json envelope) returns http:Accepted {
        lock {
            received += 1;
        }
        lock {
            lastEnvelope = envelope.clone();
        }
        return {body: {status: "ok"}};
    }

    isolated resource function post reject() returns http:InternalServerError {
        return {body: {status: "boom"}};
    }
}

isolated function receivedCount() returns int {
    lock {
        return received;
    }
}

isolated function envelope() returns json {
    lock {
        return lastEnvelope.clone();
    }
}

@test:Config
function testConsumerCanRouteAnEvent() returns error? {
    router:Router eventRouter = check new ({destinationUrl: RECEIVER_URL});

    router:RouteResult result = check eventRouter.route({
        id: "order-123",
        eventType: "order.created",
        payload: {orderId: "123", amount: 145.50},
        metadata: {origin: "checkout-api"}
    }, router:WARNING);

    test:assertEquals(result.eventId, "order-123");
    test:assertEquals(result.severity, router:WARNING);
    test:assertEquals(result.destination, router:DEFAULT_DESTINATION);
    test:assertTrue(result.delivered);
    test:assertEquals(receivedCount(), 1);

    json body = envelope();
    test:assertEquals(check body.id, "order-123");
    test:assertEquals(check body.severity, "WARNING");
    test:assertEquals(check body.metadata.origin, "checkout-api");
    test:assertEquals(check body.payload.orderId, "123");
}

@test:Config
function testConsumerSeesTypedDuplicateError() returns error? {
    router:Router eventRouter = check new ({destinationUrl: RECEIVER_URL});

    _ = check eventRouter.route({id: "order-999", eventType: "order.created"});
    router:RouteResult|router:RouterError duplicate =
        eventRouter.route({id: "order-999", eventType: "order.created"});

    test:assertTrue(duplicate is router:DuplicateEventError);
}

@test:Config
function testConsumerSeesTypedDownstreamError() returns error? {
    router:Router eventRouter = check new ({
        destinationUrl: "http://localhost:8290/hook/reject",
        circuitBreaker: ()
    });

    router:RouteResult|router:RouterError result =
        eventRouter.route({id: "order-500", eventType: "order.created"});

    test:assertTrue(result is router:DownstreamError);
    if result is router:DownstreamError {
        test:assertEquals(result.detail()?.statusCode, 500);
    }
    test:assertFalse(check eventRouter.isRouted("order-500"));
}

@test:Config
function testConsumerSeesTypedConfigError() {
    router:Router|router:ConfigError eventRouter = new ({destinationUrl: "nope"});
    test:assertTrue(eventRouter is router:ConfigError);
}
