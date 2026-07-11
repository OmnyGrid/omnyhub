import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('HubException', () {
    test('carries stable code, message and status', () {
      const e = ValidationException('bad input');
      expect(e.code, ErrorCodes.validationError);
      expect(e.message, 'bad input');
      expect(e.statusCode, 400);
    });

    test('toString includes runtimeType and code', () {
      const e = ForbiddenException('nope');
      expect(e.toString(), 'ForbiddenException(forbidden): nope');
    });

    test('status codes match HTTP semantics', () {
      expect(const UnauthorizedException().statusCode, 401);
      expect(const ForbiddenException().statusCode, 403);
      expect(const NotFoundException(message: 'x').statusCode, 404);
      expect(const RoutingException(message: 'x').statusCode, 404);
      expect(const ProxyException(message: 'x').statusCode, 502);
      expect(const NodeUnavailableException('x').statusCode, 503);
      expect(const HubTimeoutException().statusCode, 504);
    });

    test('is an Exception and matches sealed subtype checks', () {
      const HubException e = TransportException('boom');
      expect(e, isA<Exception>());
      expect(e, isA<TransportException>());
      expect(e.code, ErrorCodes.transportError);
    });

    test('defaults are sensible', () {
      expect(const UnauthorizedException().message, 'Authentication required');
      expect(const ForbiddenException().message, 'Access denied');
      expect(const HubTimeoutException().message, 'Operation timed out');
    });
  });
}
