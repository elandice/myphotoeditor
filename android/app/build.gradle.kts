import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
fun releaseKey(name: String, environmentName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotBlank() }
        ?: releaseKeys.getProperty(name)?.takeIf { it.isNotBlank() }
val releaseStore = releaseKey("storeFile", "LUMA_STORE_FILE")
val releaseStorePassword = releaseKey("storePassword", "LUMA_STORE_PASSWORD")
val releaseAlias = releaseKey("keyAlias", "LUMA_KEY_ALIAS")
val releasePassword = releaseKey("keyPassword", "LUMA_KEY_PASSWORD")
val hasReleaseKeys = listOf(releaseStore, releaseStorePassword, releaseAlias, releasePassword)
    .all { it != null }
if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) } && !hasReleaseKeys) {
    throw GradleException("Release signing is required. Configure android/key.properties or the LUMA_STORE_FILE, LUMA_STORE_PASSWORD, LUMA_KEY_ALIAS and LUMA_KEY_PASSWORD environment variables.")
}
gradle.taskGraph.whenReady {
    if (!hasReleaseKeys && allTasks.any { it.project == project && it.name.contains("Release", ignoreCase = true) }) {
        throw GradleException("Release signing is required; debug signing is never used for release builds.")
    }
}

android {
    namespace = "com.example.myphotoeditor"
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
        applicationId = "com.example.myphotoeditor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeys) {
            create("release") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeys) signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
