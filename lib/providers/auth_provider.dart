import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthState {
  const AuthState({
    this.token,
    this.user,
    this.isLoading = false,
    this.isInitialized = false,
    this.isOnboarding = false,
  });

  final String? token;
  final User? user;
  final bool isLoading;
  final bool isInitialized;
  final bool isOnboarding;

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  AuthState copyWith({
    String? token,
    User? user,
    bool? isLoading,
    bool? isInitialized,
    bool? isOnboarding,
  }) {
    return AuthState(
      token: token ?? this.token,
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      isInitialized: isInitialized ?? this.isInitialized,
      isOnboarding: isOnboarding ?? this.isOnboarding,
    );
  }
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._secureKeys, [this._ref]) : super(const AuthState());

  final SecureKeys _secureKeys;
  final Ref? _ref;

  Future<void> bootstrap() async {
    final token = await _secureKeys.getJwt();
    if (token == null || token.isEmpty) {
      state = const AuthState(isInitialized: true);
      return;
    }

    state = state.copyWith(token: token, isLoading: true);
    try {
      final service = ApiService(_secureKeys, onServerRejected: invalidateSession);
      final me = await service.getMe();
      state = state.copyWith(
        token: token,
        user: me,
        isLoading: false,
        isInitialized: true,
      );
    } on UnauthorizedException {
      await invalidateSession();
    } catch (_) {
      state = state.copyWith(isLoading: false, isInitialized: true);
    }
  }

  Future<void> login(
      {required String username, required String password}) async {
    state = state.copyWith(isLoading: true);
    try {
      final service = ApiService(_secureKeys, onServerRejected: invalidateSession);
      final result = await service.login(
        username: username,
        password: password,
      );
      final token = result['token'] as String?;
      final userMap = (result['user'] as Map<String, dynamic>?) ?? const {};
      if (token == null || token.isEmpty) {
        throw Exception('Authentication failed.');
      }

      final user = userMap.containsKey('id')
          ? User.fromJson(userMap)
          : User(id: 'local-user', username: username);

      await _secureKeys.saveJwt(token);
      state = state.copyWith(
        token: token,
        user: user,
        isLoading: false,
        isInitialized: true,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> register({
    required String username,
    required String password,
    String? email,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final service = ApiService(_secureKeys, onServerRejected: invalidateSession);
      final result = await service.register(
        username: username,
        password: password,
        email: email,
      );
      final token = result['token'] as String?;
      final userMap = (result['user'] as Map<String, dynamic>?) ?? const {};
      if (token == null || token.isEmpty) {
        throw Exception('Registration failed.');
      }

      final user = userMap.containsKey('id')
          ? User.fromJson(userMap)
          : User(id: 'local-user', username: username, email: email);

      await _secureKeys.saveJwt(token);
      state = state.copyWith(
        token: token,
        user: user,
        isLoading: false,
        isInitialized: true,
        isOnboarding: true,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> loginWithGoogle({
    String? idToken,
    String? email,
    String? googleId,
    String? name,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final service = ApiService(_secureKeys, onServerRejected: invalidateSession);
      final result = await service.loginWithGoogle(
        idToken: idToken,
        email: email,
        googleId: googleId,
        name: name,
      );
      final token = result['token'] as String?;
      final userMap = (result['user'] as Map<String, dynamic>?) ?? const {};
      if (token == null || token.isEmpty) {
        throw Exception('Google authentication failed.');
      }

      final user = userMap.containsKey('id')
          ? User.fromJson(userMap)
          : User(id: 'google-user', username: email ?? 'Google User');

      await _secureKeys.saveJwt(token);
      state = state.copyWith(
        token: token,
        user: user,
        isLoading: false,
        isInitialized: true,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> updateEmail(String email) async {
    final service = ApiService(_secureKeys);
    await service.addOrUpdateEmail(email);
    if (state.user != null) {
      state = state.copyWith(user: state.user!.copyWith(email: email));
    }
  }

  Future<void> verifyEmail(String code) async {
    final service = ApiService(_secureKeys);
    await service.verifyEmail(code);
  }

  void completeOnboarding() {
    state = state.copyWith(isOnboarding: false);
  }

  Future<void> logout() async {
    // Tell the server first while the JWT is still attached, so the session
    // (and its revocation record) actually dies — not just the local copy.
    try {
      await ApiService(_secureKeys).logout();
    } catch (_) {
      // Network failures must never trap the user inside their own account.
    }
    await invalidateSession();
  }

  Future<void> invalidateSession() async {
    await _secureKeys.clearJwt();
    await _ref?.read(chatsProvider.notifier).reset();
    await LocalDb.instance.clearAllUserData();
    state = const AuthState(isInitialized: true);
  }
}

final authProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  final secureKeys = ref.watch(secureKeysProvider);
  final controller = AuthController(secureKeys, ref);
  controller.bootstrap();
  return controller;
});
