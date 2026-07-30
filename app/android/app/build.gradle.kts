import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
