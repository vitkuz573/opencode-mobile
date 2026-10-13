plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.vitkuz573.opencodemobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.vitkuz573.opencodemobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // The musl loader ships inside the APK so Android extracts it to
            // nativeLibraryDir. That is not packaging convenience, it is the
            // whole trick.
            //
            // Android labels every file in an app's private directory
            // `app_data_file` and denies `execute_no_trans` on it, so a binary
            // fetched at runtime can be read but never started. Files that
            // arrived inside the APK are labelled `apk_data_file`, where
            // executing them is allowed. Only the loader, 723 KB, goes into the
            // APK; the 205 MB server binary stays a download and is merely read
            // by the loader.
            //
            // Legacy packaging is what makes the extraction happen at all.
            // Without it the library is mapped straight out of the APK and there
            // is no file on disk to execute.
            useLegacyPackaging = true
        }
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
