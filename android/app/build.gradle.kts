import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.google.services)
}

// The signing key lives outside git (android/keystore/, see keystore.properties) so updates
// install over the existing app and keep its downloads.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore/keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "dev.stow.android"
    compileSdk {
        version = release(37) { minorApiLevel = 1 }
    }

    defaultConfig {
        applicationId = "dev.stow.android"
        minSdk = 31
        targetSdk = 36
        versionCode = 15
        versionName = "0.9.0"
        // The Galaxy S24+ (and the Apple-silicon emulator) are 64-bit ARM; skipping the other
        // ABIs keeps yt-dlp's bundled Python and ffmpeg out of the APK four times over.
        ndk { abiFilters += "arm64-v8a" }
    }

    signingConfigs {
        create("stow") {
            if (keystoreProperties.isNotEmpty()) {
                storeFile = rootProject.file("keystore/" + keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("password")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("password")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("stow")
        }
        debug {
            signingConfig = signingConfigs.getByName("stow")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        // youtubedl-android runs Python and ffmpeg from the extracted native library folder.
        jniLibs.useLegacyPackaging = true
    }
}

dependencies {
    implementation(libs.core.ktx)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.navigation.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.compose.tooling.preview)
    debugImplementation(libs.compose.tooling)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.ui)
    implementation(libs.work.runtime)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.auth)
    implementation(libs.firebase.firestore)
    implementation(libs.firebase.messaging)
    implementation(libs.coroutines.play.services)
    implementation(libs.coil.compose)
    implementation(libs.coil.network)
    implementation(libs.code.scanner)
    implementation(libs.youtubedl.library)
    implementation(libs.youtubedl.ffmpeg)
    // The sign-in web view: no X-Requested-With header, and cookies with their real attributes.
    implementation(libs.androidx.webkit)
    testImplementation(libs.junit)
    // The real org.json (Android's is a stub in unit tests).
    testImplementation(libs.json)
}
