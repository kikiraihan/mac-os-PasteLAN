plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Satu versi untuk aplikasi Mac, server, dan Android: Resources/Info.plist (lihat AGENTS.md).
// versionName = CFBundleShortVersionString, versionCode = CFBundleVersion (nomor build, selalu naik).
val plist = rootProject.file("../Resources/Info.plist").readText()
fun plistValue(key: String) = Regex("<key>$key</key>\\s*<string>([^<]+)</string>").find(plist)?.groupValues?.get(1)
    ?: error("$key tidak ada di Resources/Info.plist")
val appVersion = plistValue("CFBundleShortVersionString")
val appBuild = plistValue("CFBundleVersion").toInt()

// Kunci tanda tangan rilis dari environment (secret CI, lihat android/README.md). Tanpa ini: hanya build debug.
val keystoreFile = System.getenv("ANDROID_KEYSTORE_FILE")?.takeIf { it.isNotBlank() && file(it).exists() }

android {
    namespace = "id.local.pastelan"
    compileSdk = 35

    defaultConfig {
        applicationId = "id.local.pastelan"
        minSdk = 26
        targetSdk = 35
        versionCode = appBuild
        versionName = appVersion
    }

    signingConfigs {
        if (keystoreFile != null) {
            create("release") {
                storeFile = file(keystoreFile)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (keystoreFile != null) signingConfig = signingConfigs.getByName("release")
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    testOptions { unitTests.isIncludeAndroidResources = true }
    lint { abortOnError = false }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.05.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Scan QR "Tambah HP" dari Mac tanpa izin kamera (pemindai Google Play services, diproses di HP).
    // HP tanpa Google Play: tempel link setup saja.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    // play-services membawa androidx.fragment lama → izin notifikasi (registerForActivityResult) bisa tidak terpanggil
    implementation("androidx.fragment:fragment-ktx:1.8.6")

    testImplementation("junit:junit:4.13.2")
    // Robolectric: layar Compose & notifikasi diuji di JVM (tanpa emulator), screenshot di app/build/screenshots/.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core-ktx:1.6.1")
    testImplementation(composeBom)
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    // org.json di unit test JVM (versi android.jar hanya stub).
    testImplementation("org.json:json:20250517")
}
