plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.davamix.i_am_ok"
    // **Pinned, not `flutter.compileSdkVersion`.** All three SDK levels below
    // read from the Flutter SDK by default, so `flutter upgrade` could move them
    // with a zero-line diff in this repo and nothing to review. Two of the three
    // are load-bearing here (see `minSdk` and `targetSdk`), and a silent change
    // to either is exactly the "hard to undo" class: it reaches users as a
    // failed install or a changed alarm policy, not as a build error.
    //
    // Raising these is a deliberate act with a device pass behind it. If a
    // future plugin needs a higher `compileSdk`, the build fails loudly, which
    // is the outcome to prefer.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by `flutter_local_notifications`, which uses `java.time` to
        // schedule zoned instants. minSdk is 24 here — deliberately low,
        // because docs/testing/device-matrix.md notes the watched person's
        // phone is likely to be old — and `java.time` only arrives natively at
        // API 26, so those two devices need the desugared library to schedule
        // a reminder at all.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.davamix.i_am_ok"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // **24, pinned.** `docs/testing/device-matrix.md` reasons that the
        // watched person's phone is likely to be old, the desugaring block above
        // exists because `java.time` is native only from 26, and
        // `LocalStore.upsertLink` avoids UPSERT syntax citing this number
        // explicitly. Flutter has raised its default before; if it does again,
        // the app silently stops installing on the phones this product is for,
        // and the comment above would be stating a fact the code no longer held.
        minSdk = 24
        // **36, pinned**, because that is what the POCO F3 pass measured against
        // — exact alarms and `POST_NOTIFICATIONS` behaviour are both
        // targetSdk-gated, and this app cannot afford a platform alarm-policy
        // change arriving without a device run.
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
