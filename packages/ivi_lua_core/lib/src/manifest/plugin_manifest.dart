import 'dart:convert';

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
        preRelease.split('.').any(
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
  }) : permissions = Set.unmodifiable(permissions);

  final String id;
  final String name;
  final SemanticVersion version;
  final String apiVersion;
  final String entrypoint;
  final Set<Capability> permissions;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version.toString(),
        'apiVersion': apiVersion,
        'entrypoint': entrypoint,
        'permissions': permissions.map((value) => value.name).toList(),
      };
}

final class PluginManifestParser {
  PluginManifestParser({
    CapabilityCatalog? capabilityCatalog,
    ApiVersionPolicy? apiVersionPolicy,
  })  : capabilityCatalog = capabilityCatalog ?? CapabilityCatalog.builtIn(),
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

    return PluginManifest(
      id: id,
      name: name,
      version: version,
      apiVersion: apiVersion,
      entrypoint: entrypoint,
      permissions: permissions,
    );
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
    final looksAbsolute = value.startsWith('/') ||
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
