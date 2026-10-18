import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flexiyo/core/constants.dart';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/key_bundle.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dio HTTP client for the Flexiyo backend; attaches the JWT to every request.
class ApiService {
  ApiService(this._secureKeys, {this.onServerRejected}) {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConstants.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _secureKeys.getJwt();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          final installationId =
              await _secureKeys.readString('flexiyo.installation_id');
          if (installationId != null && installationId.isNotEmpty) {
            options.headers['X-Installation-Id'] = installationId;
          }
          handler.next(options);
        },
        onError: (error, handler) {
          final status = error.response?.statusCode;
          if (status == 401 || status == 403) {
            if (onServerRejected != null) {
              unawaited(onServerRejected!());
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  late final Dio _dio;
  final SecureKeys _secureKeys;
  final Future<void> Function()? onServerRejected;

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    return _post(
        '/api/auth/login', {'username': username, 'password': password});
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    String? email,
  }) async {
    return _post('/api/auth/register', {
      'username': username,
      'password': password,
      if (email != null && email.isNotEmpty) 'email': email,
    });
  }

  Future<Map<String, dynamic>> checkUsernameAvailability(
      String username) async {
    final data = await _get(
      '/api/auth/check-username',
      params: {'username': username},
    );
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> loginWithGoogle({
    String? idToken,
    String? email,
    String? googleId,
    String? name,
  }) async {
    return _post('/api/auth/google', {
      if (idToken != null) 'idToken': idToken,
      if (email != null) 'email': email,
      if (googleId != null) 'googleId': googleId,
      if (name != null) 'name': name,
    });
  }

  Future<Map<String, dynamic>> addOrUpdateEmail(String email) async {
    return _post('/api/auth/email', {'email': email});
  }

  Future<Map<String, dynamic>> verifyEmail(String code) async {
    return _post('/api/auth/email/verify', {'code': code});
  }

  /// Registers this device's FCM token so background notifications reach it.
  Future<void> registerPushToken(String token,
      {required String platform}) async {
    await _post('/api/push/register', {'token': token, 'platform': platform});
  }

  /// Removes this device's token on sign-out.
  Future<void> unregisterPushToken(String token) async {
    await _post('/api/push/unregister', {'token': token});
  }

  Future<int> registerDevice(Map<String, dynamic> keyBundle) async {
    final response = await _post('/api/devices/register', keyBundle);
    return (response['deviceId'] as num?)?.toInt() ?? 0;
  }

  Future<int> getPreKeyCount() async {
    final data = await _get('/api/devices/prekeys/count');
    return (data as Map<String, dynamic>)['remaining'] as int? ?? 0;
  }

  Future<void> replenishPreKeys(
    List<Map<String, dynamic>> preKeys,
  ) async {
    await _post('/api/devices/prekeys/replenish', {'preKeys': preKeys});
  }

  Future<KeyBundle> fetchKeyBundle(String userId) async {
    // Backend serves the bundle at /key-bundle/:userId — the device id segment
    // comes AFTER the resource, not before.
    final data = await _get('/api/devices/key-bundle/$userId');
    return KeyBundle.fromJson(data as Map<String, dynamic>);
  }

  /// Announce server-side that this client is exiting; server revokes the
  /// session so the JWT dies with it. Local storage cleanup happens in auth.
  Future<void> logout() => _post('/api/auth/logout', const {});

  Future<User> getMe() async {
    final data = await _get('/api/auth/me');
    return User.fromJson(data as Map<String, dynamic>);
  }

  /// Queries the Worker's update checker for the latest release.
  ///
  /// Returns the raw release payload; callers map it via [AppUpdateInfo].
  Future<Map<String, dynamic>> checkForUpdate({
    required String version,
    required String arch,
    String platform = 'android',
  }) async {
    return _post('/api/update/check', {
      'version': version,
      'arch': arch,
      'platform': platform,
    });
  }

  Future<List<User>> searchUsers(String query) async {
    final data = await _get('/api/users/search', params: {'q': query});
    final List<dynamic> rawList =
        data is List ? data : data['users'] as List<dynamic>? ?? const [];
    return rawList
        .map((u) => User.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  /// One-seed REST payload: accepted chats + request queue in a single call.
  /// Used once after login; after that the inbox WebSocket keeps state fresh.
  Future<({List<Conversation> conversations, List<Conversation> requests})>
      getConversationSeed() async {
    final data = await _get('/api/conversations', params: {'scope': 'all'});
    final map = data as Map<String, dynamic>;
    final conversations = ((map['conversations'] as List<dynamic>?) ?? const [])
        .map((c) => Conversation.fromJson(c as Map<String, dynamic>))
        .toList();
    final requests = ((map['requests'] as List<dynamic>?) ?? const [])
        .map((r) => Conversation.fromJson(r as Map<String, dynamic>))
        .toList();
    return (conversations: conversations, requests: requests);
  }

  /// Inboxes list and message requests are the same projection — one merged
  /// endpoint. scope: 'inbox' (default) | 'requests' | 'all'.
  Future<List<Conversation>> getConversations({String scope = 'inbox'}) async {
    final data = await _get('/api/conversations', params: {'scope': scope});
    final List<dynamic> rawList = data is List
        ? data
        : data['conversations'] as List<dynamic>? ?? const [];
    return rawList
        .map((c) => Conversation.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<List<Conversation>> getMessageRequests() async {
    final data =
        await _get('/api/conversations', params: {'scope': 'requests'});
    final List<dynamic> rows =
        data is List ? data : data['requests'] as List<dynamic>? ?? const [];
    return rows
        .map((row) => Conversation.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  /// Accepts or rejects an incoming message request.
  /// Merged endpoint: PATCH /api/conversations/:id/request
  Future<void> respondToMessageRequest(
    String conversationId, {
    required bool accept,
  }) async {
    await _patch('/api/conversations/$conversationId/request', {
      'action': accept ? 'accept' : 'reject',
    });
  }

  Future<Conversation> getConversation(String conversationId) async {
    final data = await _get('/api/conversations/$conversationId');
    return Conversation.fromJson(data as Map<String, dynamic>);
  }

  Future<Conversation> getOrCreateConversation(String otherUserId) async {
    final data =
        await _post('/api/conversations', {'participantId': otherUserId});
    final payload = data['conversation'] is Map<String, dynamic>
        ? data['conversation'] as Map<String, dynamic>
        : data;
    return Conversation.fromJson(payload);
  }

  Future<void> updateDisappearingTimer(
    String conversationId,
    int timerSeconds,
  ) async {
    await _patch('/api/conversations/$conversationId/disappearing', {
      'timer': timerSeconds,
    });
  }

  Future<void> blockConversation(String conversationId) async {
    await _post('/api/conversations/$conversationId/block', const {});
  }

  Future<void> unblockConversation(String conversationId) async {
    await _delete('/api/conversations/$conversationId/block');
  }

  Future<List<Message>> getMessages(
    String conversationId, {
    int limit = 60,
    int? after,
    String? before,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (after != null) params['after'] = after;
    if (before != null) params['before'] = before;
    final data = await _get(
      '/api/conversations/$conversationId/messages',
      params: params,
    );
    final List<dynamic> rawList =
        data is List ? data : data['messages'] as List<dynamic>? ?? const [];
    return rawList
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> sendMessage(
    String conversationId, {
    required String recipientId,
    required String encryptedPayload,
    required String messageType,
    required String messageId,
    int? expiresIn,
    String? replyToId,
  }) async {
    final body = <String, dynamic>{
      'id': messageId,
      'recipientId': recipientId,
      'encryptedPayload': encryptedPayload,
      'messageType': messageType,
    };
    if (expiresIn != null && expiresIn > 0) body['expires_in'] = expiresIn;
    if (replyToId != null) body['replyToId'] = replyToId;
    return _post('/api/conversations/$conversationId/messages', body);
  }

  Future<void> editMessage(
    String conversationId,
    String messageId, {
    required String encryptedPayload,
    required int version,
    required String messageType,
  }) async {
    await _patch('/api/conversations/$conversationId/messages/$messageId', {
      'encrypted_payload': encryptedPayload,
      'version': version,
      'message_type': messageType,
    });
  }

  /// Unsend (retract for everyone). Only the original sender may call this.
  /// Pass [mediaId] when the message carried media so the server can delete
  /// the file from storage immediately.
  Future<void> unsendMessage(
    String conversationId,
    String messageId, {
    String? mediaId,
  }) async {
    final query = mediaId == null || mediaId.isEmpty ? '' : '?mediaId=$mediaId';
    await _delete(
      '/api/conversations/$conversationId/messages/$messageId$query',
    );
  }

  /// React to a message with an emoji (or toggles it off if same emoji is tapped).
  Future<Map<String, dynamic>> sendReaction(
    String conversationId,
    String messageId,
    String emoji,
  ) async {
    return _post(
      '/api/conversations/$conversationId/messages/$messageId/reaction',
      {'emoji': emoji},
    );
  }

  /// Delete for the current user only (local tombstone on server).
  Future<void> deleteMessageForMe(
    String conversationId,
    String messageId,
  ) async {
    await deleteMessagesForMe(conversationId, [messageId]);
  }

  Future<void> deleteMessagesForMe(
    String conversationId,
    List<String> messageIds,
  ) async {
    await _post(
      '/api/conversations/$conversationId/messages/delete-for-me',
      {'messageIds': messageIds},
    );
  }

  /// Builds the WebSocket URL for a given conversation, appending the JWT token.
  Future<String> buildWsUrl(String conversationId) async {
    final token = await _secureKeys.getJwt();
    final base = AppConstants.apiBaseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final encoded = Uri.encodeComponent(token ?? '');
    return '$base/api/ws/$conversationId?token=$encoded';
  }

  Future<String> buildInboxWsUrl() async {
    final token = await _secureKeys.getJwt();
    final base = AppConstants.apiBaseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final encoded = Uri.encodeComponent(token ?? '');
    return '$base/api/ws/inbox?token=$encoded';
  }

  Future<dynamic> _get(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    try {
      final resp = await _dio.get<dynamic>(path, queryParameters: params);
      return resp.data;
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await _dio.post<dynamic>(path, data: jsonEncode(body));
      return _unwrap(resp);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await _dio.patch<dynamic>(path, data: jsonEncode(body));
      return _unwrap(resp);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Future<void> _delete(String path) async {
    try {
      await _dio.delete<dynamic>(path);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Map<String, dynamic> _unwrap(Response<dynamic> resp) {
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    return {};
  }

  FlexiyoException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final message = (e.response?.data is Map)
        ? (e.response!.data as Map)['error']?.toString() ??
            e.message ??
            'Request failed'
        : e.message ?? 'Request failed';

    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return NetworkException(message);
    }
    if (status == 401 || status == 403) {
      return UnauthorizedException(message);
    }
    if (status == 404) return NotFoundException(message);
    return ApiException(message, statusCode: status);
  }

  Future<Map<String, dynamic>> markConversationRead(String conversationId) {
    return _post('/api/conversations/$conversationId/read', const {});
  }
}

final apiServiceProvider = Provider<ApiService>((ref) {
  final secureKeys = ref.watch(secureKeysProvider);
  return ApiService(
    secureKeys,
    onServerRejected: ref.read(authProvider.notifier).invalidateSession,
  );
});
