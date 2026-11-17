import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key. The build (GitHub Actions) writes
// android/key.properties from repository secrets; it is never committed.
// Without it a release build stops: an APK signed with the debug key can't
// update one people already have. To try a release build on your own
// machine anyway, add -PallowDebugSigning=true (never publish that APK).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val allowDebugSigning =
    (project.findProperty("allowDebugSigning") as String?)?.toBoolean() == true

/** A value from key.properties, or a clear error naming what's missing. */
fun signingValue(name: String): String =
    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException(
            "android/key.properties has no \"$name\". It needs storeFile, " +
                "storePassword, keyAlias and keyPassword.",
        )

android {
    namespace = "com.clienttracker.client_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.clienttracker.client_tracker"
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
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = signingValue("keyAlias")
                keyPassword = signingValue("keyPassword")
                storeFile = file(signingValue("storeFile"))
                storePassword = signingValue("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Shrink the code with R8, using the rules in proguard-rules.pro.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

// No release key: stop any release build before it makes an APK that
// can't update the installed app (unless allowed for a local try-out).
gradle.taskGraph.whenReady {
    val releasing = allTasks.any {
        it.project == project && it.name.contains("Release") &&
            (it.name.startsWith("assemble") || it.name.startsWith("bundle") ||
                it.name.startsWith("package"))
    }
    if (releasing && !keystorePropertiesFile.exists() && !allowDebugSigning) {
        throw GradleException(
            "No release signing key: android/key.properties is missing. " +
                "The build on GitHub writes it from the repository secrets. " +
                "For a local try-out only, add -PallowDebugSigning=true.",
        )
    }
}
