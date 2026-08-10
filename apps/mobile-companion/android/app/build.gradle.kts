import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

fun loadDotEnv(file: File): Map<String, String> {
    if (!file.isFile) return emptyMap()
    return file.useLines { lines ->
        lines.mapNotNull { rawLine ->
            val line = rawLine.trim()
            if (line.isEmpty() || line.startsWith("#")) return@mapNotNull null
            val separator = line.indexOf('=')
            if (separator <= 0) return@mapNotNull null
            val name = line.substring(0, separator).trim()
            var value = line.substring(separator + 1).trim()
            if (value.length >= 2 &&
                ((value.startsWith('"') && value.endsWith('"')) ||
                    (value.startsWith('\'') && value.endsWith('\'')))
            ) {
                value = value.substring(1, value.length - 1)
            }
            name to value
        }.toMap()
    }
}

val localEnvironment = loadDotEnv(rootProject.file("../../../.env.local"))

fun String.asBuildConfigString(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val developmentGoogleApiKey: String =
    sequenceOf(
        System.getenv("MAPPY_DEV_GOOGLE_API_KEY"),
        localEnvironment["MAPPY_DEV_GOOGLE_API_KEY"],
        localProperties.getProperty("mappy.devGoogleApiKey"),
    ).firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()

android {
    namespace = "com.leapwardkoex.mappy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.leapwardkoex.mappy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["mappyGoogleMapsApiKey"] = developmentGoogleApiKey
        buildConfigField(
            "String",
            "MAPPY_DEV_GOOGLE_API_KEY",
            developmentGoogleApiKey.asBuildConfigString()
        )
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            manifestPlaceholders["mappyGoogleMapsApiKey"] = ""
            buildConfigField("String", "MAPPY_DEV_GOOGLE_API_KEY", "\"\"")
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
    implementation("io.rebble.pebblekit2:client:1.1.0")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("org.json:json:20240303")
    testImplementation(kotlin("test-junit"))
}
