import com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --- Firebase telemetry, config-file-gated -----------------------------------
//
// `android/app/google-services.json` is GIT-IGNORED and generated, exactly like
// `key.properties`: CI writes it in android.yml from the AIGAMMON_FIREBASE_*
// repo variables plus the FIREBASE_ANDROID_APP_ID secret, and a developer who
// wants telemetry from a local build downloads the real one from the Firebase
// console (⚙ Project settings → Your apps → Android app). See firebase/DEPLOY.md.
//
// Why the file has to exist at all, given every Firebase value also arrives as
// a --dart-define: the three Gradle plugins below read the app id from the
// `google_app_id` string RESOURCE that `com.google.gms.google-services`
// generates out of this file. A dart-define is a Dart compile-time constant and
// is invisible to Gradle, so there is no substitute. Without the plugins:
//   * a SIGSEGV in the Rust engine `.so` produces no Crashlytics report at all
//     (NDK capture is a Gradle-plugin feature, not an SDK one), and
//   * Performance Monitoring loses its AUTOMATIC network and screen traces
//     (the app's own custom traces need no instrumentation and work regardless).
//
// The gate mirrors the signing gate below and the AIGAMMON_FIREBASE_* gates in
// the workflows: file absent -> plugins are simply not applied and the build
// succeeds with Dart-only crash reporting. It must not be a hard failure, or a
// fresh clone could not build the Android app at all.
val googleServicesFile = file("google-services.json")
val hasFirebaseConfig = googleServicesFile.exists()

if (hasFirebaseConfig) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
    apply(plugin = "com.google.firebase.firebase-perf")
} else {
    logger.lifecycle(
        "NOTE: android/app/google-services.json is missing — the Firebase " +
            "Gradle plugins are not applied. Crash reporting from this build " +
            "will be DART-ONLY (a native crash in the engine .so goes " +
            "unreported) and Performance Monitoring gets no automatic traces. " +
            "See firebase/DEPLOY.md."
    )
}

// --- Release signing, credential-gated ---------------------------------------
//
// `android/key.properties` is GIT-IGNORED and holds the upload-key credentials:
//
//     storeFile=aigammon-upload.jks     (relative to android/)
//     storePassword=…
//     keyAlias=aigammon-upload
//     keyPassword=…
//
// On a developer machine you create it yourself; in CI `android.yml` writes it
// from four repository secrets and base64-decodes the .jks next to it. See
// android/KEYSTORE_SETUP.md for both paths.
//
// The gate mirrors the AIGAMMON_FIREBASE_* and iOS-signing gates already in this
// repo: when the credentials are ABSENT the build still succeeds, falling back
// to Flutter's debug keystore with a loud warning, so CI is green before the
// secrets exist and `flutter run --release` keeps working locally. What it must
// never do is take the debug key SILENTLY — that is how a store-rejected,
// un-updatable APK ships.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

val keystoreFile: File? = keystoreProperties.getProperty("storeFile")
    ?.let { rootProject.file(it) }
    ?.takeIf { it.exists() }

val hasReleaseSigning = keystoreFile != null &&
    keystoreProperties.getProperty("storePassword") != null &&
    keystoreProperties.getProperty("keyAlias") != null &&
    keystoreProperties.getProperty("keyPassword") != null

if (!hasReleaseSigning) {
    logger.lifecycle(
        "WARNING: android/key.properties is missing or incomplete — the RELEASE " +
            "build will be signed with the DEBUG keystore. It is installable for " +
            "testing but CANNOT be published. See android/KEYSTORE_SETUP.md."
    )
}

android {
    namespace = "com.xmelon.aigammon_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xmelon.aigammon_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Pinned explicitly (was flutter.minSdkVersion, currently 24) so the
        // native engine .so ABI expectations don't silently shift with Flutter.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = keystoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Documented, warned-about fallback — see the gate above.
                signingConfigs.getByName("debug")
            }

            if (hasFirebaseConfig) {
                // Turns on generation of the Breakpad symbol files Crashlytics
                // needs to turn a native stack of raw addresses into function
                // names. Generation is not upload: the plugin creates the
                // symbols during assembly, but they only reach Firebase when
                // `uploadCrashlyticsSymbolFileRelease` is run. See the
                // "Native symbols" note in firebase/DEPLOY.md.
                //
                // `unstrippedNativeLibsDir` is required here rather than
                // optional because the engine arrives as PREBUILT .so files
                // staged into jniLibs by cargo-ndk, not through an
                // externalNativeBuild the plugin could locate on its own. This
                // is the directory cargo-ndk writes and it is unstripped;
                // AGP strips its own copy on the way into the APK, which is why
                // the plugin must be pointed at the source rather than the
                // packaged artifact.
                configure<CrashlyticsExtension> {
                    nativeSymbolUploadEnabled = true
                    unstrippedNativeLibsDir = file("src/main/jniLibs")
                }
            }
        }
    }
}

dependencies {
    if (hasFirebaseConfig) {
        // `firebase-crashlytics-ndk` is the artifact that installs the native
        // signal handlers. The firebase_crashlytics Flutter plugin depends only
        // on `firebase-crashlytics` (Dart/JVM), so without this line the
        // Crashlytics Gradle plugin would generate symbols for crashes that are
        // never captured. The BOM version tracks `FirebaseSDKVersion` in
        // firebase_core's android/gradle.properties — bump both together when
        // firebase_core is upgraded, or Gradle reports a version conflict.
        implementation(platform("com.google.firebase:firebase-bom:34.15.0"))
        implementation("com.google.firebase:firebase-crashlytics-ndk")
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
