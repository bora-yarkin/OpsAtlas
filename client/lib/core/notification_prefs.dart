// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Notification preference models, persistence helpers, and editors.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'api/auth_store.dart';
import 'i18n/app_localizations.dart';

class NotificationPrefs {
  final bool includeView;
  final bool includeSearch;
  final bool includePublish;
  final bool includeTask;
  final String digestMode;
  final int digestHour;
  final int digestMinute;

  const NotificationPrefs({
    required this.includeView,
    required this.includeSearch,
    required this.includePublish,
    required this.includeTask,
    required this.digestMode,
    required this.digestHour,
    required this.digestMinute,
  });

  static const defaults = NotificationPrefs(
    includeView: false,
    includeSearch: false,
    includePublish: true,
    includeTask: true,
    digestMode: 'realtime',
    digestHour: 9,
    digestMinute: 0,
  );

  NotificationPrefs copyWith({
    bool? includeView,
    bool? includeSearch,
    bool? includePublish,
    bool? includeTask,
    String? digestMode,
    int? digestHour,
    int? digestMinute,
  }) {
    return NotificationPrefs(
      includeView: includeView ?? this.includeView,
      includeSearch: includeSearch ?? this.includeSearch,
      includePublish: includePublish ?? this.includePublish,
      includeTask: includeTask ?? this.includeTask,
      digestMode: digestMode ?? this.digestMode,
      digestHour: digestHour ?? this.digestHour,
      digestMinute: digestMinute ?? this.digestMinute,
    );
  }

  Map<String, dynamic> toJson() => {
    'include_view': includeView,
    'include_search': includeSearch,
    'include_publish': includePublish,
    'include_task': includeTask,
    'digest_mode': digestMode,
    'digest_hour': digestHour,
    'digest_minute': digestMinute,
  };

  factory NotificationPrefs.fromJson(Map<String, dynamic> json) {
    final rawHour = (json['digest_hour'] as num?)?.toInt() ?? 9;
    final rawMinute = (json['digest_minute'] as num?)?.toInt() ?? 0;
    return NotificationPrefs(
      includeView: json['include_view'] == true,
      includeSearch: json['include_search'] == true,
      includePublish: json['include_publish'] != false,
      includeTask: json['include_task'] != false,
      digestMode: (json['digest_mode'] ?? 'realtime').toString(),
      digestHour: rawHour.clamp(0, 23).toInt(),
      digestMinute: rawMinute.clamp(0, 59).toInt(),
    );
  }

  bool allowsEventType(String eventType) {
    if (eventType == 'view') return includeView;
    if (eventType == 'search') return includeSearch;
    if (eventType == 'publish') return includePublish;
    if (eventType == 'task_created' || eventType == 'task_updated') {
      return includeTask;
    }
    return true;
  }

  String scheduleSummaryText(AppLocalizations l10n) {
    if (digestMode == 'hourly') {
      return '${l10n.text('notification_schedule_hourly_prefix')} :${digestMinute.toString().padLeft(2, '0')}';
    }
    if (digestMode == 'daily') {
      return '${l10n.text('notification_schedule_daily_prefix')} ${digestHour.toString().padLeft(2, '0')}:${digestMinute.toString().padLeft(2, '0')}';
    }
    return l10n.text('notification_schedule_realtime');
  }

  DateTime? nextDeliveryWindow(DateTime now) {
    if (digestMode == 'realtime') return null;
    if (digestMode == 'hourly') {
      var next = DateTime(now.year, now.month, now.day, now.hour, digestMinute);
      if (!next.isAfter(now)) {
        next = next.add(const Duration(hours: 1));
      }
      return next;
    }

    var next = DateTime(now.year, now.month, now.day, digestHour, digestMinute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }
}

final notificationPrefsProvider =
    ChangeNotifierProvider<NotificationPrefsController>((ref) {
      final api = ref.watch(apiClientProvider);
      final auth = ref.watch(authStoreProvider);
      return NotificationPrefsController(api, auth)..load();
    });

class NotificationPrefsController extends ChangeNotifier {
  static const _key = 'notification_preferences_v1';
  final ApiClient _api;
  final AuthStore _auth;

  NotificationPrefs _value = NotificationPrefs.defaults;
  bool _loadedFromServer = false;
  int _updateVersion = 0;
  bool _disposed = false;

  NotificationPrefsController(this._api, this._auth);

  NotificationPrefs get value => _value;
  bool get loadedFromServer => _loadedFromServer;

  bool get includeView => _value.includeView;
  bool get includeSearch => _value.includeSearch;
  bool get includePublish => _value.includePublish;
  bool get includeTask => _value.includeTask;
  String get digestMode => _value.digestMode;
  int get digestHour => _value.digestHour;
  int get digestMinute => _value.digestMinute;

  bool allowsEventType(String eventType) => _value.allowsEventType(eventType);

  Future<void> load() async {
    if (_auth.isLoggedIn) {
      try {
        final response = await _api.dio.get(
          '/auth/me/notification-preferences',
        );
        if (_disposed) {
          return;
        }
        final data = response.data;
        if (data is Map) {
          _value = NotificationPrefs.fromJson(data.cast<String, dynamic>());
          _loadedFromServer = true;
          _safeNotifyListeners();
          await _persistLocalCache(_value);
          return;
        }
      } on DioException {
        // fall back to local cache
      } catch (_) {
        // fall back to local cache
      }
    }

    final sp = await SharedPreferences.getInstance();
    if (_disposed) {
      return;
    }
    final raw = sp.getString(_key);
    if (raw == null || raw.trim().isEmpty) {
      _value = NotificationPrefs.defaults;
      _loadedFromServer = false;
      _safeNotifyListeners();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _value = NotificationPrefs.fromJson(decoded.cast<String, dynamic>());
        _loadedFromServer = false;
        _safeNotifyListeners();
        return;
      }
    } catch (_) {
      // ignore parse issues and reset to defaults
    }
    _value = NotificationPrefs.defaults;
    _loadedFromServer = false;
    _safeNotifyListeners();
  }

  Future<void> update(NotificationPrefs next) async {
    final requestVersion = ++_updateVersion;
    _value = next;
    _safeNotifyListeners();
    await _persistLocalCache(next);

    if (!_auth.isLoggedIn) {
      if (requestVersion == _updateVersion && _loadedFromServer) {
        _loadedFromServer = false;
        _safeNotifyListeners();
      }
      return;
    }

    try {
      final response = await _api.dio.patch(
        '/auth/me/notification-preferences',
        data: next.toJson(),
      );
      if (_disposed || requestVersion != _updateVersion) return;
      final data = response.data;
      if (data is Map) {
        _value = NotificationPrefs.fromJson(data.cast<String, dynamic>());
        _loadedFromServer = true;
        _safeNotifyListeners();
        await _persistLocalCache(_value);
      }
    } on DioException {
      if (_disposed || requestVersion != _updateVersion) return;
      _loadedFromServer = false;
      _safeNotifyListeners();
    } catch (_) {
      if (_disposed || requestVersion != _updateVersion) return;
      _loadedFromServer = false;
      _safeNotifyListeners();
    }
  }

  Future<void> _persistLocalCache(NotificationPrefs next) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(next.toJson()));
  }

  void _safeNotifyListeners() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
