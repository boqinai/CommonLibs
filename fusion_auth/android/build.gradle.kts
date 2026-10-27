group = "com.boqinai.fusionauth"
version = "1.0"

plugins {
    id("com.android.library")
}

// Vendored Aliyun 融合认证 SDK 1.2.16 (no Umeng; the SDK skips it), as a file
// Maven repo (AGP forbids direct local .aar deps in library modules). The
// app module resolves this dependency too, so the repo is also registered
// on every project of the host build (no host gradle change needed).
val fusionRepo = uri("${projectDir}/repo")
repositories {
    maven { url = fusionRepo }
}
rootProject.allprojects {
    repositories {
        maven { url = fusionRepo }
    }
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
