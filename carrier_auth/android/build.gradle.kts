group = "com.boqinai.carrierauth"
version = "0.1.0"

plugins { id("com.android.library") }

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}
android {
    namespace = "com.boqinai.carrierauth"
    compileSdk = 36
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig { minSdk = 24 }
}
dependencies {
    // Shared dependency is resolved once, including its native resources.
    implementation(project(":fusion_auth"))
    implementation("com.alicom.fusion:fusionauth:1.2.16@aar")
    implementation("androidx.appcompat:appcompat:1.7.1")
}
