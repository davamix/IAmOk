pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // Reads android/app/google-services.json and generates the string resources
    // Firebase initialises itself from. Without it `Firebase.initializeApp()`
    // throws at runtime with a message about a missing default app rather than
    // about a missing plugin, which is a long way from the cause.
    //
    // `google-services.json` is committed ON PURPOSE — its API key ships inside
    // the APK and authorises nothing on its own. The real controls are the
    // security rules plus App Check. See docs/security/secrets-policy.md.
    id("com.google.gms.google-services") version "4.4.4" apply false
}

include(":app")
