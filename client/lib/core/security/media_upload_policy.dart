// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Media upload policy helpers that cache or normalize backend constraints.

import '../api/api_client.dart';

const List<String> _fallbackAllowedExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'pdf',
  'txt',
  'md',
  'csv',
  'json',
  'zip',
  'docx',
  'xlsx',
  'pptx',
  'mp4',
  'webm',
  'mov',
  'm4v',
  'mp3',
  'wav',
  'ogg',
  'm4a',
];

const List<String> _fallbackAllowedMimeTypes = <String>[
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'application/pdf',
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
  'application/zip',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'video/mp4',
  'video/webm',
  'video/quicktime',
  'audio/mpeg',
  'audio/wav',
  'audio/ogg',
  'audio/x-m4a',
];

const Set<String> _genericMimeTypes = <String>{
  'application/octet-stream',
  'binary/octet-stream',
};

class MediaUploadPolicy {
  final int maxUploadMb;
  final Set<String> allowedExtensions;
  final Set<String> allowedMimeTypes;
  final Map<String, MediaUsageUploadRule> usageRules;

  MediaUploadPolicy({
    required this.maxUploadMb,
    required Iterable<String> allowedExtensions,
    required Iterable<String> allowedMimeTypes,
    this.usageRules = const <String, MediaUsageUploadRule>{},
  }) : allowedExtensions = allowedExtensions
           .map((value) => value.trim().toLowerCase())
           .where((value) => value.isNotEmpty)
           .toSet(),
       allowedMimeTypes = allowedMimeTypes
           .map((value) => value.trim().toLowerCase())
           .where((value) => value.isNotEmpty)
           .toSet();

  int get maxUploadBytes => maxUploadMb * 1024 * 1024;

  factory MediaUploadPolicy.fromJson(Map<String, dynamic> json) {
    final rawMaxUploadMb = json['max_upload_mb'];
    final maxUploadMb = rawMaxUploadMb is int
        ? rawMaxUploadMb
        : int.tryParse(rawMaxUploadMb?.toString() ?? '') ?? 25;

    final rawExtensions = json['allowed_extensions'];
    final rawMimeTypes = json['allowed_mime_types'];
    final rawUsageRules = json['usage_rules'];
    final usageRules = <String, MediaUsageUploadRule>{};
    if (rawUsageRules is Map) {
      for (final entry in rawUsageRules.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (key.isEmpty || entry.value is! Map) {
          continue;
        }
        usageRules[key] = MediaUsageUploadRule.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
      }
    }
    return MediaUploadPolicy(
      maxUploadMb: maxUploadMb < 1 ? 1 : maxUploadMb,
      allowedExtensions: rawExtensions is List
          ? rawExtensions.map((value) => value.toString())
          : _fallbackAllowedExtensions,
      allowedMimeTypes: rawMimeTypes is List
          ? rawMimeTypes.map((value) => value.toString())
          : _fallbackAllowedMimeTypes,
      usageRules: usageRules,
    );
  }

  factory MediaUploadPolicy.fallback() {
    return MediaUploadPolicy(
      maxUploadMb: 25,
      allowedExtensions: _fallbackAllowedExtensions,
      allowedMimeTypes: _fallbackAllowedMimeTypes,
    );
  }
}

class MediaUsageUploadRule {
  final String? label;
  final List<String> guidance;
  final Set<String> allowedExtensions;
  final Set<String> allowedMimeTypes;
  final int? maxUploadMb;
  final int? minWidth;
  final int? minHeight;
  final int? maxWidth;
  final int? maxHeight;
  final double? aspectRatioMin;
  final double? aspectRatioMax;
  final bool squareRequired;

  const MediaUsageUploadRule({
    this.label,
    this.guidance = const <String>[],
    this.allowedExtensions = const <String>{},
    this.allowedMimeTypes = const <String>{},
    this.maxUploadMb,
    this.minWidth,
    this.minHeight,
    this.maxWidth,
    this.maxHeight,
    this.aspectRatioMin,
    this.aspectRatioMax,
    this.squareRequired = false,
  });

  factory MediaUsageUploadRule.fromJson(Map<String, dynamic> json) {
    return MediaUsageUploadRule(
      label: (json['label'] ?? '').toString().trim().isEmpty
          ? null
          : (json['label'] ?? '').toString().trim(),
      guidance: json['guidance'] is List
          ? (json['guidance'] as List)
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      allowedExtensions: json['allowed_extensions'] is List
          ? (json['allowed_extensions'] as List)
                .map((value) => value.toString().trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toSet()
          : const <String>{},
      allowedMimeTypes: json['allowed_mime_types'] is List
          ? (json['allowed_mime_types'] as List)
                .map((value) => value.toString().trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toSet()
          : const <String>{},
      maxUploadMb: _asIntOrNull(json['max_upload_mb']),
      minWidth: _asIntOrNull(json['min_width']),
      minHeight: _asIntOrNull(json['min_height']),
      maxWidth: _asIntOrNull(json['max_width']),
      maxHeight: _asIntOrNull(json['max_height']),
      aspectRatioMin: _asDoubleOrNull(json['aspect_ratio_min']),
      aspectRatioMax: _asDoubleOrNull(json['aspect_ratio_max']),
      squareRequired: json['square_required'] == true,
    );
  }
}

enum UploadValidationIssueCode { fileTooLarge, fileTypeNotAllowed }

class UploadValidationIssue {
  final UploadValidationIssueCode code;
  final String filename;
  final int maxUploadMb;

  const UploadValidationIssue({
    required this.code,
    required this.filename,
    required this.maxUploadMb,
  });
}

Future<MediaUploadPolicy> fetchMediaUploadPolicy(ApiClient api) async {
  try {
    final response = await api.dio.get('/media/policy');
    final data = response.data;
    if (data is Map) {
      return MediaUploadPolicy.fromJson(data.cast<String, dynamic>());
    }
  } catch (_) {
    return MediaUploadPolicy.fallback();
  }
  return MediaUploadPolicy.fallback();
}

UploadValidationIssue? validateUploadSelection({
  required List<int> bytes,
  required String filename,
  String? extension,
  String? mimeType,
  String? usage,
  required MediaUploadPolicy policy,
}) {
  final usageRule = usage == null
      ? null
      : policy.usageRules[usage.trim().toLowerCase()];
  final maxUploadBytes =
      (usageRule?.maxUploadMb ?? policy.maxUploadMb) * 1024 * 1024;
  if (bytes.length > maxUploadBytes) {
    return UploadValidationIssue(
      code: UploadValidationIssueCode.fileTooLarge,
      filename: _displayUploadFilename(filename),
      maxUploadMb: usageRule?.maxUploadMb ?? policy.maxUploadMb,
    );
  }

  final normalizedExtension = normalizeUploadExtension(extension, filename);
  final allowedExtensions = usageRule?.allowedExtensions.isNotEmpty == true
      ? usageRule!.allowedExtensions
      : policy.allowedExtensions;
  if (normalizedExtension == null ||
      !allowedExtensions.contains(normalizedExtension)) {
    return UploadValidationIssue(
      code: UploadValidationIssueCode.fileTypeNotAllowed,
      filename: _displayUploadFilename(filename),
      maxUploadMb: usageRule?.maxUploadMb ?? policy.maxUploadMb,
    );
  }

  final normalizedMimeType = inferMimeTypeFromUpload(
    extension: normalizedExtension,
    mimeType: mimeType,
  );
  final allowedMimeTypes = usageRule?.allowedMimeTypes.isNotEmpty == true
      ? usageRule!.allowedMimeTypes
      : policy.allowedMimeTypes;
  if (normalizedMimeType != null &&
      normalizedMimeType.isNotEmpty &&
      !allowedMimeTypes.contains(normalizedMimeType)) {
    return UploadValidationIssue(
      code: UploadValidationIssueCode.fileTypeNotAllowed,
      filename: _displayUploadFilename(filename),
      maxUploadMb: usageRule?.maxUploadMb ?? policy.maxUploadMb,
    );
  }

  return null;
}

String? normalizeUploadExtension(String? extension, String filename) {
  final direct = (extension ?? '').trim().toLowerCase().replaceFirst('.', '');
  if (direct.isNotEmpty) {
    return direct;
  }
  final trimmedFilename = filename.trim();
  final dotIndex = trimmedFilename.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex >= trimmedFilename.length - 1) {
    return null;
  }
  return trimmedFilename.substring(dotIndex + 1).trim().toLowerCase();
}

String? inferMimeTypeFromUpload({String? extension, String? mimeType}) {
  final normalizedMimeType = (mimeType ?? '').trim().toLowerCase();
  if (normalizedMimeType.isNotEmpty &&
      !_genericMimeTypes.contains(normalizedMimeType)) {
    return normalizedMimeType;
  }

  switch ((extension ?? '').trim().toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'csv':
      return 'text/csv';
    case 'json':
      return 'application/json';
    case 'zip':
      return 'application/zip';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mov':
      return 'video/quicktime';
    case 'm4v':
      return 'video/mp4';
    case 'mp3':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
      return 'audio/ogg';
    case 'm4a':
      return 'audio/x-m4a';
    default:
      return normalizedMimeType.isEmpty ? null : normalizedMimeType;
  }
}

String _displayUploadFilename(String filename) {
  final trimmed = filename.trim();
  return trimmed.isEmpty ? 'upload.bin' : trimmed;
}

int? _asIntOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString().trim());
}

double? _asDoubleOrNull(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? '').toString().trim());
}
