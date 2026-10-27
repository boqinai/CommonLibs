group = "com.boqinai.fusionauth"
version = "1.0"

plugins {
    id("com.android.library")
}

// Vendored Aliyun 融合认证 SDK 1.2.16 (no Umeng; the SDK skips it), as a file
// Maven repo (AGP forbids direct local .aar deps in library modules).
//
// Hosts that use dependencyResolutionManagement /
// RepositoriesMode.FAIL_ON_PROJECT_REPOS must add this repo in
// settings.gradle(.kts) instead of relying on allprojects injection:
//
//   dependencyResolutionManagement {
//     repositories {
//       maven { url = uri("/absolute/path/to/fusion_auth/android/repo") }
//       // or: maven { url = uri("${settingsDir}/.../fusion_auth/android/repo") }
//     }
//   }
//
// Flutter's default templates still allow project repositories, so the
// allprojects registration below keeps zero-config for typical apps
// (including Penny). Failures are logged rather than aborting the build.
val fusionRepo = uri("${projectDir}/repo")
repositories {
    maven { url = fusionRepo }
}
try {
    rootProject.allprojects {
        repositories {
            maven { url = fusionRepo }
        }
    }
} catch (e: Exception) {
    logger.warn(
        "fusion_auth: could not register file Maven repo via allprojects " +
            "(${e.message}). If the host uses FAIL_ON_PROJECT_REPOS, add " +
            "${projectDir}/repo to settings.gradle dependencyResolutionManagement.",
    )
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "com.boqinai.fusionauth"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }
}

dependencies {
    implementation("com.alicom.fusion:fusionauth:1.2.16@aar")
    // The SDK's pages extend AppCompatActivity (see Aliyun demo).
    implementation("androidx.appcompat:appcompat:1.7.1")
}
