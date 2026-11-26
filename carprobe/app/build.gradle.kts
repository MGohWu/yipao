plugins {
    id("com.android.application")
}

android {
    namespace = "app.leaprun.carprobe"
    compileSdk = 34

    defaultConfig {
        applicationId = "app.leaprun.carprobe"
        minSdk = 26
        // 车机多是 Android 9~11，targetSdk 停在 29：Android 14 起截屏要前台服务类型，
        // 探针没必要为那个再绕一圈。
        targetSdk = 29
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
