import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "com.flexiyo.flexiyo/app_update",
      binaryMessenger: engineBridge.pluginRegistry.registrar(forPlugin: "AppUpdateChannel")!.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getVersion":
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        result(version)
      case "openUrl":
        guard let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString)
        else {
          result(FlutterError(code: "NO_URL", message: "A url argument is required", details: nil))
          return
        }
        DispatchQueue.main.async {
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
