package com.flexiyo.flexiyo

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// MethodChannel `com.flexiyo.flexiyo/app_update` exposing version, ABI, install
// permission, URL opening and APK install for the in-app updater.
class MainActivity : FlutterActivity() {
    private val channelName = "com.flexiyo.flexiyo/app_update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVersion" -> result.success(getVersion())

                    "getArchitecture" -> result.success(getArchitecture())

                    "canInstallPackages" -> result.success(canInstallPackages())

                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }

                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("NO_URL", "A url argument is required", null)
                        } else {
                            openUrl(url)
                            result.success(null)
                        }
                    }

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("NO_PATH", "A path argument is required", null)
                        } else {
                            installApk(path)
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun getVersion(): String {
        return try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "0.0.0"
        } catch (_: Exception) {
            "0.0.0"
        }
    }

    private fun getArchitecture(): String {
        val abis = Build.SUPPORTED_ABIS
        return if (!abis.isNullOrEmpty()) abis[0] else "arm64-v8a"
    }

    private fun canInstallPackages(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun openUrl(url: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
