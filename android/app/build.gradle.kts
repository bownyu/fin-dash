import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties().apply {
    val properties = rootProject.file("key.properties")
    if (properties.isFile) properties.inputStream().use { load(it) }
}
val releaseStore = System.getenv("FINDASH_KEYSTORE_FILE") ?: releaseKeys.getProperty("storeFile")

android {
    namespace = "com.findash.fin_dash"
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
        applicationId = "com.findash.fin_dash"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("ANDROID_STORE_PASSWORD") ?: releaseKeys.getProperty("storePassword")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: releaseKeys.getProperty("keyAlias")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Local development may use debug; published updates retain one private signing identity.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    androidResources {
        // Read the bundled model directly through AssetManager, without an extra extracted copy.
        noCompress += "onnx"
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/sherpa-onnx-1.13.8.aar"))
    testImplementation("junit:junit:4.13.2")
}

val checkOfflineVoiceAssets by tasks.registering {
    doLast {
        for (path in listOf("libs/sherpa-onnx-1.13.8.aar",
            "src/main/assets/sensevoice-small/model.int8.onnx",
            "src/main/assets/sensevoice-small/tokens.txt",
            "src/main/assets/sensevoice-small/silero_vad.onnx")) {
            check(file(path).isFile) {
                "Missing bundled voice asset: $path. Run scripts/prepare-offline-voice.ps1 first."
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(checkOfflineVoiceAssets) }
