import 'dart:convert';

import '../can/can_models.dart';
import '../errors/plugin_exception.dart';
import '../permissions/capability.dart';

final class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease,
    this.build,
  });

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;
  final String? build;

  factory SemanticVersion.parse(String source) {
    final match = _pattern.firstMatch(source);
    if (match == null) {
      throw FormatException('Invalid semantic version: $source');
    }
    final preRelease = match.group(4);
    if (preRelease != null &&
        preRelease
            .split('.')
            .any(
              (identifier) =>
                  identifier.length > 1 &&
                  identifier.startsWith('0') &&
                  int.tryParse(identifier) != null,
            )) {
      throw FormatException(
        'Numeric pre-release identifiers must not contain leading zeroes: '
        '$source',
      );
    }
    return SemanticVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      preRelease: preRelease,
      build: match.group(5),
    );
  }

  @override
  int compareTo(SemanticVersion other) {
    final core = _compareCore(other);
    if (core != 0) return core;
    if (preRelease == null && other.preRelease == null) return 0;
    if (preRelease == null) return 1;
    if (other.preRelease == null) return -1;
    final left = preRelease!.split('.');
    final right = other.preRelease!.split('.');
    for (var index = 0; index < left.length && index < right.length; index++) {
      final comparison = _compareIdentifier(left[index], right[index]);
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  }

  int _compareCore(SemanticVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }

  static int _compareIdentifier(String left, String right) {
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null) return -1;
    if (rightNumber != null) return 1;
    return left.compareTo(right);
  }

  bool operator <(SemanticVersion other) => compareTo(other) < 0;
  bool operator <=(SemanticVersion other) => compareTo(other) <= 0;
  bool operator >(SemanticVersion other) => compareTo(other) > 0;
  bool operator >=(SemanticVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is SemanticVersion && toString() == other.toString();

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease, build);

  @override
  String toString() {
    final prereleasePart = preRelease == null ? '' : '-$preRelease';
    final buildPart = build == null ? '' : '+$build';
    return '$major.$minor.$patch$prereleasePart$buildPart';
  }
}

abstract interface class ApiVersionPolicy {
  bool supports(String requestedVersion);
  String describe();
}

final class ExactApiVersionPolicy implements ApiVersionPolicy {
  ExactApiVersionPolicy(Iterable<String> supportedVersions)
    : supportedVersions = Set.unmodifiable(supportedVersions);

  final Set<String> supportedVersions;

  @override
  bool supports(String requestedVersion) =>
      supportedVersions.contains(requestedVersion);

  @override
  String describe() => supportedVersions.join(', ');
}

/// Strongly validated data from a plugin's manifest.json.
final class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.entrypoint,
    required Iterable<Capability> permissions,
    CanAccessGrant? canAccess,
  }) : permissions = Set.unmodifiable(permissions),
       canAccess = canAccess ?? CanAccessGrant();

  final String id;
  final String name;
  final SemanticVersion version;
  final String apiVersion;
  final String entrypoint;
  final Set<Capability> permissions;
  final CanAccessGrant canAccess;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version.toString(),
    'apiVersion': apiVersion,
    'entrypoint': entrypoint,
    'permissions': permissions.map((value) => value.name).toList(),
    if (canAccess.readFilters.isNotEmpty ||
        canAccess.writeFilters.isNotEmpty ||
        canAccess.maxSendRatePerSecond > 0)
      'can': {
        'read': canAccess.readFilters.map(_canFilterToJson).toList(),
        'write': canAccess.writeFilters.map(_canFilterToJson).toList(),
        'maxSendRatePerSecond': canAccess.maxSendRatePerSecond,
      },
  };

  static Map<String, Object?> _canFilterToJson(CanFilter filter) => {
    'bus': filter.bus,
    if (!filter.matchesAllIds)
      if (filter.ids.length == 1)
        'id': filter.ids.single
      else
        'ids': filter.ids,
    'mask': filter.mask,
    if (filter.extended != null) 'extended': filter.extended,
    if (filter.includeRemote) 'includeRemote': true,
    if (filter.includeErrors) 'includeErrors': true,
  };
}

final class PluginManifestParser {
  PluginManifestParser({
    CapabilityCatalog? capabilityCatalog,
    ApiVersionPolicy? apiVersionPolicy,
  }) : capabilityCatalog = capabilityCatalog ?? CapabilityCatalog.builtIn(),
       apiVersionPolicy =
           apiVersionPolicy ?? ExactApiVersionPolicy(const {'1'});

  static final RegExp _idPattern = RegExp(
    r'^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9_-]*)+$',
  );
  static final RegExp _apiVersionPattern = RegExp(r'^[1-9]\d*$');

  final CapabilityCatalog capabilityCatalog;
  final ApiVersionPolicy apiVersionPolicy;

  PluginManifest parseString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error, stackTrace) {
      throw PluginManifestException(
        'Malformed JSON: ${error.message}',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const PluginManifestException('Manifest root must be an object.');
    }
    return parseMap(decoded);
  }

  PluginManifest parseMap(Map<String, Object?> json) {
    final id = _requiredString(json, 'id');
    if (!_idPattern.hasMatch(id)) {
      throw PluginManifestException(
        'Invalid plugin ID "$id". Use a lower-case reverse-domain ID.',
        pluginId: id,
      );
    }
    final name = _requiredString(json, 'name', pluginId: id);
    if (name.length > 128) {
      throw PluginManifestException(
        'Plugin name must be at most 128 characters.',
        pluginId: id,
      );
    }
    final versionSource = _requiredString(json, 'version', pluginId: id);
    late final SemanticVersion version;
    try {
      version = SemanticVersion.parse(versionSource);
    } on FormatException catch (error, stackTrace) {
      throw PluginManifestException(
        error.message,
        pluginId: id,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    final apiVersion = _requiredString(json, 'apiVersion', pluginId: id);
    if (!_apiVersionPattern.hasMatch(apiVersion)) {
      throw PluginManifestException(
        'Invalid API version "$apiVersion".',
        pluginId: id,
      );
    }
    if (!apiVersionPolicy.supports(apiVersion)) {
      throw PluginManifestException(
        'Unsupported API version "$apiVersion". Supported: '
        '${apiVersionPolicy.describe()}.',
        pluginId: id,
      );
    }
    final entrypoint = _requiredString(json, 'entrypoint', pluginId: id);
    _validateEntrypoint(entrypoint, pluginId: id);

    final permissionValues = json['permissions'];
    if (permissionValues is! List<Object?>) {
      throw PluginManifestException(
        '"permissions" must be an array of strings.',
        pluginId: id,
      );
    }
    final permissionNames = <String>{};
    final permissions = <Capability>{};
    for (final value in permissionValues) {
      if (value is! String || value.trim() != value || value.isEmpty) {
        throw PluginManifestException(
          'Every permission must be a non-empty string.',
          pluginId: id,
        );
      }
      if (!permissionNames.add(value)) {
        throw PluginManifestException(
          'Duplicate permission "$value".',
          pluginId: id,
        );
      }
      permissions.add(capabilityCatalog.resolve(value, pluginId: id));
    }

    final canAccess = _parseCanAccess(json['can'], pluginId: id);
    final requestsCanRead = permissions.contains(BuiltInCapabilities.canRead);
    final requestsCanWrite = permissions.contains(BuiltInCapabilities.canWrite);
    if (requestsCanRead && !canAccess.permitsReads) {
      throw PluginManifestException(
        'Permission "can.read" requires at least one can.read filter.',
        pluginId: id,
      );
    }
    if (!requestsCanRead && canAccess.readFilters.isNotEmpty) {
      throw PluginManifestException(
        'CAN read filters require permission "can.read".',
        pluginId: id,
      );
    }
    if (requestsCanWrite && !canAccess.permitsWrites) {
      throw PluginManifestException(
        'Permission "can.write" requires a write filter and a positive '
        'maxSendRatePerSecond.',
        pluginId: id,
      );
    }
    if (!requestsCanWrite &&
        (canAccess.writeFilters.isNotEmpty ||
            canAccess.maxSendRatePerSecond > 0)) {
      throw PluginManifestException(
        'CAN write policy requires permission "can.write".',
        pluginId: id,
      );
    }

    return PluginManifest(
      id: id,
      name: name,
      version: version,
      apiVersion: apiVersion,
      entrypoint: entrypoint,
      permissions: permissions,
      canAccess: canAccess,
    );
  }

  static CanAccessGrant _parseCanAccess(
    Object? value, {
    required String pluginId,
  }) {
    if (value == null) return CanAccessGrant();
    if (value is! Map<String, Object?>) {
      throw PluginManifestException(
        '"can" must be an object.',
        pluginId: pluginId,
      );
    }
    const knownKeys = {'read', 'write', 'maxSendRatePerSecond'};
    final unknown = value.keys.where((key) => !knownKeys.contains(key));
    if (unknown.isNotEmpty) {
      throw PluginManifestException(
        'Unknown CAN policy field "${unknown.first}".',
        pluginId: pluginId,
      );
    }

    List<CanFilter> parseFilters(String field, {required bool write}) {
      final raw = value[field];
      if (raw == null) return const [];
      if (raw is! List<Object?>) {
        throw PluginManifestException(
          '"can.$field" must be an array of filter objects.',
          pluginId: pluginId,
        );
      }
      return [
        for (var index = 0; index < raw.length; index++)
          _parseCanFilter(
            raw[index],
            pluginId: pluginId,
            field: 'can.$field[$index]',
            write: write,
          ),
      ];
    }

    final rate = value['maxSendRatePerSecond'] ?? 0;
    if (rate is! int || rate < 0 || rate > 100000) {
      throw PluginManifestException(
        '"can.maxSendRatePerSecond" must be an integer in 0..100000.',
        pluginId: pluginId,
      );
    }
    try {
      return CanAccessGrant(
        readFilters: parseFilters('read', write: false),
        writeFilters: parseFilters('write', write: true),
        maxSendRatePerSecond: rate,
      );
    } on ArgumentError catch (error, stackTrace) {
      throw PluginManifestException(
        'Invalid CAN policy: ${error.message}',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static CanFilter _parseCanFilter(
    Object? value, {
    required String pluginId,
    required String field,
    required bool write,
  }) {
    if (value is! Map<String, Object?>) {
      throw PluginManifestException(
        '"$field" must be an object.',
        pluginId: pluginId,
      );
    }
    const knownKeys = {
      'bus',
      'id',
      'ids',
      'mask',
      'extended',
      'includeRemote',
      'includeErrors',
    };
    final unknown = value.keys.where((key) => !knownKeys.contains(key));
    if (unknown.isNotEmpty) {
      throw PluginManifestException(
        'Unknown CAN filter field "${unknown.first}" in "$field".',
        pluginId: pluginId,
      );
    }
    final bus = value['bus'];
    final id = value['id'];
    final rawIds = value['ids'];
    final mask = value['mask'];
    final extended = value['extended'];
    final includeRemote = value['includeRemote'] ?? false;
    final includeErrors = value['includeErrors'] ?? false;
    if (bus is! String ||
        (id != null && id is! int) ||
        (mask != null && mask is! int) ||
        (extended != null && extended is! bool) ||
        includeRemote is! bool ||
        includeErrors is! bool ||
        (rawIds != null &&
            (rawIds is! List<Object?> || rawIds.any((item) => item is! int)))) {
      throw PluginManifestException(
        'Invalid field type in "$field".',
        pluginId: pluginId,
      );
    }
    if (write && includeErrors) {
      throw PluginManifestException(
        '"$field" cannot allow controller error frames.',
        pluginId: pluginId,
      );
    }
    try {
      final ids = rawIds is List<Object?> ? rawIds.cast<int>() : null;
      return CanFilter(
        bus: bus,
        id: id as int?,
        ids: ids,
        mask: mask as int?,
        extended: extended as bool?,
        includeRemote: includeRemote,
        includeErrors: includeErrors,
      );
    } on ArgumentError catch (error, stackTrace) {
      throw PluginManifestException(
        'Invalid "$field": ${error.message}',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static String _requiredString(
    Map<String, Object?> json,
    String key, {
    String? pluginId,
  }) {
    final value = json[key];
    if (value is! String || value.trim() != value || value.isEmpty) {
      throw PluginManifestException(
        '"$key" must be a non-empty string without surrounding whitespace.',
        pluginId: pluginId,
      );
    }
    return value;
  }

  static void _validateEntrypoint(String value, {required String pluginId}) {
    final segments = value.split('/');
    final looksAbsolute =
        value.startsWith('/') ||
        value.startsWith(r'\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value);
    if (looksAbsolute ||
        value.contains(r'\') ||
        segments.any(
          (segment) => segment.isEmpty || segment == '..' || segment == '.',
        ) ||
        !value.toLowerCase().endsWith('.lua')) {
      throw PluginManifestException(
        'Entrypoint must be a relative .lua path inside the plugin directory.',
        pluginId: pluginId,
      );
    }
  }
}

/// A validated, duplicate-free group of discovered manifests.
final class PluginManifestCollection {
  PluginManifestCollection(Iterable<PluginManifest> manifests)
    : manifests = List.unmodifiable(manifests) {
    final ids = <String>{};
    for (final manifest in this.manifests) {
      if (!ids.add(manifest.id)) {
        throw PluginManifestException(
          'Duplicate plugin ID "${manifest.id}".',
          pluginId: manifest.id,
        );
      }
    }
  }

  final List<PluginManifest> manifests;
}
