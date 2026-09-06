import java.util.Properties
import java.security.KeyStore
import java.security.cert.X509Certificate

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
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

// Resolve the app-restricted Maps SDK key for Flutter CLI, VS Code, and CI.
// This key is intentionally embedded in every Android variant.
val androidSdkApiKey: String =
    sequenceOf(
        providers.environmentVariable("MAPPY_ANDROID_SDK_API_KEY").orNull,
        localEnvironment["MAPPY_ANDROID_SDK_API_KEY"],
        localProperties.getProperty("mappy.androidSdkApiKey"),
    ).firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()

fun String.asBuildConfigString(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val developmentGoogleApiKey: String =
    sequenceOf(
        System.getenv("MAPPY_DEV_GOOGLE_API_KEY"),
        localEnvironment["MAPPY_DEV_GOOGLE_API_KEY"],
        localProperties.getProperty("mappy.devGoogleApiKey"),
    ).firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()

fun releaseSigningValue(environmentName: String, propertyName: String): String =
    sequenceOf(
        System.getenv(environmentName),
        localProperties.getProperty(propertyName),
    ).firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()

val releaseStoreFilePath = releaseSigningValue(
    "MAPPY_RELEASE_STORE_FILE",
    "mappy.releaseStoreFile"
)
val releaseStorePassword = releaseSigningValue(
    "MAPPY_RELEASE_STORE_PASSWORD",
    "mappy.releaseStorePassword"
)
val releaseKeyAlias = releaseSigningValue(
    "MAPPY_RELEASE_KEY_ALIAS",
    "mappy.releaseKeyAlias"
)
val releaseKeyPassword = releaseSigningValue(
    "MAPPY_RELEASE_KEY_PASSWORD",
    "mappy.releaseKeyPassword"
)
val releaseSigningValues = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val releaseSigningConfigured = releaseSigningValues.all(String::isNotBlank)
val releaseSigningPartiallyConfigured = releaseSigningValues.any(String::isNotBlank) &&
    !releaseSigningConfigured

check(!releaseSigningPartiallyConfigured) {
    "Release signing is only partially configured. Set all MAPPY_RELEASE_* environment " +
        "variables or all mappy.release* entries in android/local.properties."
}

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
        buildConfigField("int", "MAPPY_TILE_TRANSFER_PACING_MILLIS", "30")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["mappyGoogleMapsApiKey"] = androidSdkApiKey
        buildConfigField(
            "String",
            "MAPPY_DEV_GOOGLE_API_KEY",
            developmentGoogleApiKey.asBuildConfigString()
        )
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFilePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            val tilePacing = providers.gradleProperty("mappyTilePacingMillis").orNull?.toInt() ?: 30
            require(tilePacing in listOf(0, 10, 30)) { "Tile pacing trial must be 0, 10, or 30 ms." }
            buildConfigField("int", "MAPPY_TILE_TRANSFER_PACING_MILLIS", tilePacing.toString())
            // Install offline benchmarks beside the user's app and keep its data intact.
            if (providers.gradleProperty("mappyTileBenchmark").orNull == "true") {
                applicationIdSuffix = ".tilebench"
                buildConfigField("String", "MAPPY_DEV_GOOGLE_API_KEY", "\"\"")
                manifestPlaceholders["mappyGoogleMapsApiKey"] = ""
            }
        }
        release {
            proguardFiles("proguard-rules.pro")
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
            buildConfigField("String", "MAPPY_DEV_GOOGLE_API_KEY", "\"\"")
        }
    }
}

val verifyReleaseSigning by tasks.registering {
    group = "verification"
    description = "Fails release packaging when protected signing is unavailable."
    doLast {
        check(androidSdkApiKey.isNotBlank()) {
            "MAPPY_ANDROID_SDK_API_KEY is required for release packaging. Set it in the " +
                "environment, repository-root .env.local, or mappy.androidSdkApiKey " +
                "in android/local.properties."
        }
        check(releaseSigningConfigured) {
            "Release signing is required. Configure MAPPY_RELEASE_STORE_FILE, " +
                "MAPPY_RELEASE_STORE_PASSWORD, MAPPY_RELEASE_KEY_ALIAS, and " +
                "MAPPY_RELEASE_KEY_PASSWORD (or their android/local.properties equivalents)."
        }
        val configuredStoreFile = rootProject.file(releaseStoreFilePath)
        check(configuredStoreFile.isFile) {
            "Configured release keystore does not exist: $releaseStoreFilePath"
        }

        val storePasswordChars = releaseStorePassword.toCharArray()
        val loadedKeyStore = try {
            listOf("JKS", "PKCS12").firstNotNullOfOrNull { storeType ->
                runCatching {
                    KeyStore.getInstance(storeType).apply {
                        configuredStoreFile.inputStream().use { input ->
                            load(input, storePasswordChars)
                        }
                    }
                }.getOrNull()
            }
        } finally {
            storePasswordChars.fill('\u0000')
        }
        check(loadedKeyStore != null) {
            "Configured release keystore could not be opened."
        }

        val keyPasswordChars = releaseKeyPassword.toCharArray()
        val signingKey = try {
            runCatching { loadedKeyStore.getKey(releaseKeyAlias, keyPasswordChars) }.getOrNull()
        } finally {
            keyPasswordChars.fill('\u0000')
        }
        check(signingKey != null && loadedKeyStore.isKeyEntry(releaseKeyAlias)) {
            "Configured release key alias or key password is invalid."
        }

        val certificate = loadedKeyStore.getCertificate(releaseKeyAlias) as? X509Certificate
        check(certificate != null) {
            "Configured release key does not have an X.509 certificate."
        }
        runCatching { certificate.checkValidity() }.getOrElse {
            error("Configured release signing certificate is not currently valid.")
        }
        val debugCertificateName = Regex(
            "(?:^|,)\\s*CN=Android Debug\\s*(?:,|$)",
            RegexOption.IGNORE_CASE
        )
        check(
            !releaseKeyAlias.equals("androiddebugkey", ignoreCase = true) &&
                !debugCertificateName.containsMatchIn(certificate.subjectX500Principal.name) &&
                !debugCertificateName.containsMatchIn(certificate.issuerX500Principal.name)
        ) {
            "Android debug certificates are forbidden for release packaging."
        }
    }
}

tasks.matching {
    it.name == "assembleRelease" ||
        it.name == "bundleRelease" ||
        it.name.startsWith("packageRelease") ||
        it.name == "signReleaseBundle" ||
        it.name == "makeApkFromBundleForRelease"
}.configureEach {
    dependsOn(verifyReleaseSigning)
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
    implementation("at.yawk.lz4:lz4-java:1.11.2")
    implementation("io.rebble.pebblekit2:client:1.1.0")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    testImplementation("org.json:json:20240303")
    testImplementation(kotlin("test-junit"))
}
