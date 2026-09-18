plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.firebrat.firebrat_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.firebrat.firebrat_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // CI injects android/key.properties from secrets (see
            // .github/workflows/flutter-release.yml) so every release APK
            // shares ONE signature. Without it (local sandbox builds),
            // fall back to debug keys so `flutter run --release` works.
            // (Debug-signed CI builds each had a fresh random key, which is
            // why installing one release over another failed signature checks.)
            val keystoreProps = java.util.Properties()
            val keystoreFile = rootProject.file("key.properties")
            if (keystoreFile.exists()) {
                keystoreProps.load(java.io.FileInputStream(keystoreFile))
            }
            if (keystoreProps.containsKey("keyAlias")) {
                signingConfigs.create("release") {
                    keyAlias = keystoreProps["keyAlias"] as String
                    keyPassword = keystoreProps["keyPassword"] as String
                    storeFile = file(keystoreProps["storeFile"] as String)
                    storePassword = keystoreProps["storePassword"] as String
                }
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}
