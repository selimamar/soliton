import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key (docs/releasing.md), from android/key.properties
// on your computer or from SOLITON_ANDROID_* environment variables in the
// release workflow. Neither is in git. Without either, release builds are
// signed with the debug key, which is fine for trying them but not for
// handing out: an APK signed with the real key won't install over it.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
fun signingValue(property: String, env: String): String? =
    keyProperties.getProperty(property) ?: System.getenv(env)?.takeIf { it.isNotEmpty() }
val releaseStoreFile = signingValue("storeFile", "SOLITON_ANDROID_KEYSTORE")

android {
    namespace = "io.github.selimamar.soliton"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.selimamar.soliton"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                // Relative paths are relative to android/, where key.properties is.
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = signingValue("storePassword", "SOLITON_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "SOLITON_ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "SOLITON_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("No release key (android/key.properties): signing the release build with the debug key.")
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
