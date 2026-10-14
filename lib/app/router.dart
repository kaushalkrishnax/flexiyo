import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/screens/auth/login_screen.dart';
import 'package:flexiyo/screens/auth/register_screen.dart';
import 'package:flexiyo/screens/chats/chats_screen.dart';
import 'package:flexiyo/screens/chats/message_requests_screen.dart';
import 'package:flexiyo/screens/chats/new_chat_screen.dart';
import 'package:flexiyo/screens/conversation/conversation_screen.dart';
import 'package:flexiyo/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class AppRouterNotifier extends ChangeNotifier {
  AppRouterNotifier(this._ref) {
    _ref.listen<AuthState>(
      authProvider,
      (previous, next) {
        if (previous?.isAuthenticated != next.isAuthenticated) {
          notifyListeners();
        }
      },
    );
  }

  final Ref _ref;

  String? redirect(BuildContext context, GoRouterState state) {
    final isLoggedIn = _ref.read(authProvider).isAuthenticated;
    final isAuthRoute = state.matchedLocation == '/login' ||
        state.matchedLocation == '/register';

    if (!isLoggedIn && !isAuthRoute) return '/login';
    if (isLoggedIn && isAuthRoute) return '/chats';
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

  return GoRouter(
    initialLocation: '/chats',
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: [
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
