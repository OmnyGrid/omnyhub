import 'dart:async';

import '../core/connection.dart';
import 'hub_request.dart';
import 'hub_response.dart';

/// Handles a [HubRequest] and produces a [HubResponse].
///
/// The fundamental unit the pipeline, services and the router are built from.
typedef HubRequestHandler = Future<HubResponse> Function(HubRequest request);

/// Wraps a [HubRequestHandler], returning a new one — the composition primitive
/// for the request pipeline (authentication, logging, CORS, ACME challenge,
/// error mapping, ...).
typedef Middleware = HubRequestHandler Function(HubRequestHandler inner);

/// Handles an upgraded WebSocket [Connection] together with the originating
/// [HubRequest] (for routing context — host, path, principal).
typedef ConnectionHandler =
    FutureOr<void> Function(Connection connection, HubRequest request);
