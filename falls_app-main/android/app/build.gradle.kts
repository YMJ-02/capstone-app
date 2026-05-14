plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.fall_detection_app"
    
    // 최신 SDK 및 NDK 설정
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    // 🔥 'default'를 'defaultConfig'로 수정했습니다.
    defaultConfig {
        applicationId = "com.example.fall_detection_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    // 최신 권장 방식(compilerOptions)으로 경고 해결
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}