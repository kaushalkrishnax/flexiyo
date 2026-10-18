// Web only allows sign-in from Google's own rendered button; every other
// platform uses the app-styled button.
export 'google_sign_in_button_io.dart'
    if (dart.library.js_interop) 'google_sign_in_button_web.dart';
