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
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false

    // The three Firebase Gradle plugins. Declared here so they land on the
    // build classpath, `apply false` because whether they are APPLIED depends
    // on a file that may not exist — app/build.gradle.kts applies them by id at
    // configuration time, gated on `app/google-services.json` being present.
    // The Kotlin DSL `plugins {}` block cannot make that decision itself: it is
    // a restricted script block with no access to `file()`.
    //
    // Versions are pinned deliberately, and they are a set, not three
    // independent choices: Crashlytics v3 requires AGP 8.1+ and google-services
    // 4.4.1+, and v3.0.7 is the first release that survives AGP 9 (this project
    // is on AGP 9.0.1). google-services is the prerequisite for both of the
    // others — it is what generates the `google_app_id` string resource they
    // read. The FlutterFire example projects pin much older versions (4.3.15 /
    // 2.8.1 / 1.4.1); those predate AGP 9 and must not be copied.
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.firebase.crashlytics") version "3.0.7" apply false
    id("com.google.firebase.firebase-perf") version "2.0.2" apply false
}

include(":app")
