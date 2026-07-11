import '../shared/errors/error_codes.dart';
import '../shared/errors/hub_exception.dart';
import 'service.dart';

/// Holds the services registered with a hub and resolves a request path to the
/// service mounted at the longest matching prefix.
///
/// Registration and removal are dynamic: services may be added or removed while
/// the hub is running.
class ServiceRegistry {
  final Map<String, Service> _byName = {};

  /// All registered services, in registration order.
  Iterable<Service> get all => _byName.values;

  /// The number of registered services.
  int get length => _byName.length;

  /// Whether a service named [name] is registered.
  bool contains(String name) => _byName.containsKey(name);

  /// The service named [name], or `null`.
  Service? get(String name) => _byName[name];

  /// Registers [service].
  ///
  /// Throws [ValidationException] if another service already uses the same
  /// name.
  void register(Service service) {
    if (_byName.containsKey(service.name)) {
      throw ValidationException(
        "A service named '${service.name}' is already registered",
      );
    }
    _byName[service.name] = service;
  }

  /// Removes and returns the service named [name].
  ///
  /// Throws [NotFoundException] if no such service is registered.
  Service remove(String name) {
    final service = _byName.remove(name);
    if (service == null) {
      throw NotFoundException(
        code: ErrorCodes.serviceNotFound,
        message: "No service named '$name'",
      );
    }
    return service;
  }

  /// Resolves the service that should handle [path]: the one whose normalised
  /// [Service.mount] is the longest prefix of [path]. Returns `null` if none
  /// match.
  Service? resolve(String path) {
    Service? best;
    var bestLength = -1;
    for (final service in _byName.values) {
      final mount = normalizeMount(service.mount);
      if (_mountMatches(mount, path) && mount.length > bestLength) {
        best = service;
        bestLength = mount.length;
      }
    }
    return best;
  }

  /// Normalises a mount path to a canonical form: a leading slash, no trailing
  /// slash, with the root represented as `/`.
  static String normalizeMount(String mount) {
    var m = mount.trim();
    if (m.isEmpty) return '/';
    if (!m.startsWith('/')) m = '/$m';
    while (m.length > 1 && m.endsWith('/')) {
      m = m.substring(0, m.length - 1);
    }
    return m;
  }

  static bool _mountMatches(String mount, String path) {
    if (mount == '/') return true;
    return path == mount || path.startsWith('$mount/');
  }
}
