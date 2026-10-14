import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthState {
  const AuthState({this.token, this.user, this.isLoading = false});

  final String? token;
  final User? user;
  final bool isLoading;

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  AuthState copyWith({String? token, User? user, bool? isLoading}) {
    return AuthState(
      token: token ?? this.token,
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._secureKeys) : super(const AuthState());

  final SecureKeys _secureKeys;

  Future<void> bootstrap() async {
    final token = await _secureKeys.getJwt();
    if (token == null || token.isEmpty) {
      state = const AuthState();
      return;
    }

    state = state.copyWith(token: token, isLoading: true);
    try {
      final service = ApiService(_secureKeys);
      final me = await service.getMe();
      state = state.copyWith(token: token, user: me, isLoading: false);
    } catch (_) {
      await _secureKeys.clearJwt();
      state = const AuthState();
    }
  }

  Future<void> login(
      {required String username, required String password}) async {
    state = state.copyWith(isLoading: true);
    try {
      final service = ApiService(_secureKeys);
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
      );
    } catch (error) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> register(
      {required String username, required String password}) async {
    state = state.copyWith(isLoading: true);
    try {
      final service = ApiService(_secureKeys);
      final result =
          await service.register(username: username, password: password);
      final token = result['token'] as String?;
      final userMap = (result['user'] as Map<String, dynamic>?) ?? const {};
      if (token == null || token.isEmpty) {
        throw Exception('Registration failed.');
      }

      final user = userMap.containsKey('id')
          ? User.fromJson(userMap)
          : User(id: 'local-user', username: username);

      await _secureKeys.saveJwt(token);
      state = state.copyWith(
        token: token,
        user: user,
        isLoading: false,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> logout() async {
    await _secureKeys.clearJwt();
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  final secureKeys = ref.watch(secureKeysProvider);
  final controller = AuthController(secureKeys);
  controller.bootstrap();
  return controller;
});
