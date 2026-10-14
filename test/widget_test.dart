import 'package:flexiyo/app/app.dart';
import 'package:flexiyo/core/exceptions.dart';
import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/screens/auth/login_screen.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAuthController extends AuthController {
  FakeAuthController({this.error}) : super(SecureKeys.instance);

  final Object? error;

  @override
  Future<void> login({required String username, required String password}) async {
    state = state.copyWith(isLoading: true);
    if (error != null) {
      state = state.copyWith(isLoading: false);
      throw error!;
    }
    state = state.copyWith(
      token: 'mock-jwt-token',
      user: User(id: 'u1', username: username),
      isLoading: false,
    );
  }
}

void main() {
  testWidgets('Flexiyo app loads the login screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: FlexiyoApp()),
    );

    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets(
      'retains username, clears password, and shows server error message on login failure',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (ref) => FakeAuthController(
              error: const UnauthorizedException('Invalid credentials'),
            ),
          ),
        ],
        child: const MaterialApp(
          home: LoginScreen(),
        ),
      ),
    );

    final usernameField = find.byType(TextField).at(0);
    final passwordField = find.byType(TextField).at(1);
    final loginButton = find.text('Log in');

    await tester.enterText(usernameField, 'my_username');
    await tester.enterText(passwordField, 'my_secret_pass');
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    // Username MUST still be retained
    expect(find.text('my_username'), findsOneWidget);
    // Password MUST be cleared
    expect(find.text('my_secret_pass'), findsNothing);
    // Server error message MUST be visible
    expect(find.text('Invalid credentials'), findsOneWidget);
  });

  testWidgets(
      'shows custom server error message like rate limit or validation failure',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (ref) => FakeAuthController(
              error: const ApiException(
                'Too many requests. Please slow down.',
                statusCode: 429,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: LoginScreen(),
        ),
      ),
    );

    final usernameField = find.byType(TextField).at(0);
    final passwordField = find.byType(TextField).at(1);
    final loginButton = find.text('Log in');

    await tester.enterText(usernameField, 'rate_limited_user');
    await tester.enterText(passwordField, 'password123');
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(find.text('rate_limited_user'), findsOneWidget);
    expect(find.text('password123'), findsNothing);
    expect(find.text('Too many requests. Please slow down.'), findsOneWidget);
  });

  testWidgets(
      'shows validation error when fields are empty without clearing input',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: LoginScreen(),
        ),
      ),
    );

    final loginButton = find.text('Log in');
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(
      find.text('Please enter both your username and password.'),
      findsOneWidget,
    );
  });
}
