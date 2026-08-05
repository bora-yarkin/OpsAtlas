// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared request-error formatting helpers for user-facing messages.

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import '../i18n/app_localizations.dart';

String requestErrorMessage(
  Object error, {
  BuildContext? context,
  String? fallbackMessage,
}) {
  if (error is DioException) {
    return dioErrorMessage(
      error,
      context: context,
      fallbackMessage: fallbackMessage,
    );
  }
  final text = error.toString().trim();
  if (text.isNotEmpty) {
    return text;
  }
  return _fallbackRequestMessage(context, fallbackMessage);
}

String dioErrorMessage(
  DioException error, {
  BuildContext? context,
  String? fallbackMessage,
}) {
  final data = error.response?.data;
  if (data is Map && data['detail'] != null) {
    final detail = data['detail'].toString().trim();
    if (detail.isNotEmpty) {
      return detail;
    }
  }
  if (data is String) {
    final detail = data.trim();
    if (detail.isNotEmpty) {
      return detail;
    }
  }
  final message = error.message?.trim();
  if (message != null && message.isNotEmpty) {
    return message;
  }
  return _fallbackRequestMessage(context, fallbackMessage);
}

String _fallbackRequestMessage(BuildContext? context, String? fallbackMessage) {
  final fallback = fallbackMessage?.trim();
  if (fallback != null && fallback.isNotEmpty) {
    return fallback;
  }
  if (context != null) {
    return AppLocalizations.of(context).text('request_failed');
  }
  return const AppLocalizations(Locale('en')).text('request_failed');
}
