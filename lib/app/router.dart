import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/screens/auth/login_screen.dart';
import 'package:flexiyo/screens/auth/register_screen.dart';
import 'package:flexiyo/screens/chats/chats_screen.dart';
import 'package:flexiyo/screens/chats/chat_state_lists_screen.dart';
import 'package:flexiyo/screens/chats/message_requests_screen.dart';
import 'package:flexiyo/screens/chats/new_chat_screen.dart';
import 'package:flexiyo/screens/conversation/conversation_screen.dart';
import 'package:flexiyo/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

final initialSessionProvider = Provider<bool>((ref) => false);

class AppRouterNotifier extends ChangeNotifier {
  AppRouterNotifier(this._ref) {
    _ref.listen<AuthState>(
      authProvider,
      (previous, next) {
        if (previous?.isAuthenticated != next.isAuthenticated ||
            previous?.isInitialized != next.isInitialized) {
          notifyListeners();
        }
      },
    );
  }

  final Ref _ref;
  String? _pendingDeepLink;

  String? redirect(BuildContext context, GoRouterState state) {
    final auth = _ref.read(authProvider);
    final hasSession = _ref.read(initialSessionProvider);
    final location = state.matchedLocation;
    final uri = state.uri.toString();
    final isAuthRoute = location == '/login' || location == '/register';

    // Normalize custom scheme deep links like flexiyo://chats/123
    if (state.uri.scheme == 'flexiyo' &&
        state.uri.host.isNotEmpty &&
        state.uri.host != 'flexiyo.pages.dev') {
      final host = state.uri.host;
      final path = state.uri.path;
      final query = state.uri.query.isNotEmpty ? '?${state.uri.query}' : '';
      return '/$host$path$query';
    }

    if (!auth.isInitialized) {
      if (location != '/login' &&
          location != '/register' &&
          location != '/') {
        _pendingDeepLink = uri;
      }
      return hasSession || isAuthRoute ? null : '/login';
    }

    if (location == '/') {
      if (auth.isAuthenticated) {
        final target = _pendingDeepLink;
        _pendingDeepLink = null;
        if (target != null &&
            target != '/' &&
            !target.startsWith('/login')) {
          return target;
        }
        return '/chats';
      }
      return '/login';
    }

    if (!auth.isAuthenticated && !isAuthRoute) return '/login';
    if (auth.isAuthenticated && isAuthRoute) {
      if (auth.isOnboarding && location == '/register') {
        return null;
      }
      final target = _pendingDeepLink;
      _pendingDeepLink = null;
      if (target != null &&
          target != '/' &&
          !target.startsWith('/login') &&
          !target.startsWith('/register')) {
        return target;
      }
      return '/chats';
    }
    return null;
  }
}

final routerNotifierProvider = Provider<AppRouterNotifier>((ref) {
  final notifier = AppRouterNotifier(ref);
  ref.onDispose(notifier.dispose);
  return notifier;
});

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(routerNotifierProvider);
  final hasSession = ref.watch(initialSessionProvider);

  return GoRouter(
    initialLocation: hasSession ? '/chats' : '/login',
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: [
      GoRoute(
        path: '/',
        name: 'root',
        redirect: (context, state) {
          final auth = ref.read(authProvider);
          if (!auth.isInitialized) {
            final hasSession = ref.read(initialSessionProvider);
            return hasSession ? '/chats' : '/login';
          }
          return auth.isAuthenticated ? '/chats' : '/login';
        },
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        name: 'register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/chats',
        name: 'chats',
        builder: (context, state) => const ChatsScreen(),
        routes: [
          GoRoute(
            path: 'new',
            name: 'new-chat',
            builder: (context, state) => const NewChatScreen(),
          ),
          GoRoute(
            path: 'requests',
            name: 'message-requests',
            builder: (context, state) => const MessageRequestsScreen(),
            routes: [
              GoRoute(
                path: 'restricted',
                name: 'restricted-chats',
                builder: (context, state) => const RestrictedChatsScreen(),
              ),
              GoRoute(
                path: 'blocked',
                name: 'blocked-chats',
                builder: (context, state) => const BlockedChatsScreen(),
              ),
            ],
          ),
          GoRoute(
            path: ':conversationId',
            name: 'conversation',
            builder: (context, state) {
              final conversationId = state.pathParameters['conversationId']!;
              return ConversationScreen(
                conversationId: conversationId,
                isMessageRequest:
                    state.uri.queryParameters['request'] == 'true',
                browseMode: state.uri.queryParameters['browse'],
              );
            },
          ),
        ],
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text(
          'Route not found: ${state.matchedLocation}',
          style: const TextStyle(fontSize: 16),
        ),
      ),
    ),
  );
});
