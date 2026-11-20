import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

// AGP 9 起 Kotlin 支持已内建在 android 插件里，不再单独套 kotlin-android。
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// 高德 key 从 local.properties 读，不进 git、不写死在 Manifest 里。
// 缺失时给空串：地图会鉴权失败显示黑图，但编译不断，方便没配 key 的人跑其它功能。
val amapKey: String = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}.getProperty("AMAP_KEY", "")


android {
    namespace = "org.yipao.app"
    // backdrop（液态玻璃）要求 37；targetSdk 留在 36 不动。
    // 37 走的是新的 minor 版本命名（平台包叫 android-37.0），得带上 compileSdkMinor。
    compileSdk = 37
    compileSdkMinor = 0

    defaultConfig {
        applicationId = "org.yipao.app"
        // 抬到 31：蓝牙钥匙要扫描 BLE，Android 12 以下扫描强制绑定「精确定位」权限，
        // 12 起才能用 BLUETOOTH_SCAN + neverForLocation 绕开。为了一个都不要定位权限，
        // 直接放弃 Android 11 及以下，代码里也就不用留低版本分支。
        minSdk = 31
        targetSdk = 36
        versionCode = 12
        versionName = "1.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Manifest 里用 ${AMAP_KEY} 占位，值来自 local.properties。
        manifestPlaceholders["AMAP_KEY"] = amapKey

        ndk {
            // 只打 64 位。高德的 so 光 armeabi-v7a 那份就 13MB，而 minSdk 31（2021 年）
            // 往后的机器早就没有纯 32 位的了——Google Play 从 2019 年 8 月起就要求
            // 应用必须提供 64 位版本。x86/x86_64 一并去掉：开发机是 Apple Silicon，
            // 模拟器镜像本身就是 arm64——真要在 Intel 机器上跑模拟器，再把 x86_64 加回来。
            abiFilters += "arm64-v8a"
        }
    }

    // 正式签名凭据从工程根目录的 keystore.properties 读（不进 git，见 .gitignore，格式见 README）。
    // 缺失时 release 回退 debug 签名，保证没配凭据的机器也能直接编过——只是签的是
    // 本机自动生成的 debug key，不能拿去发布。
    val keystoreProps: Properties? = rootProject.file("keystore.properties")
        .takeIf { it.exists() }
        ?.let { f -> Properties().apply { f.inputStream().use { load(it) } } }

    signingConfigs {
        if (keystoreProps != null) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // R8：压缩 + 混淆业务代码。keep 规则见 proguard-rules.pro，
            // 库的 keep 大多靠各自 AAR 自带的 consumer 规则。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // 配了 keystore.properties 就用正式 key，否则回退 debug 签名（编得过、但别发布）。
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        optIn.addAll(
            "androidx.compose.material3.ExperimentalMaterial3Api",
            "androidx.compose.material3.ExperimentalMaterial3ExpressiveApi",
            "dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi"
        )
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.icons.extended)
    implementation(libs.haze)
    implementation(libs.haze.materials)
    implementation(libs.backdrop)
    implementation(libs.shapes)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.amap.map3d)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.bouncycastle)
    implementation(libs.glance.appwidget)
    implementation(libs.glance.material3)
    implementation(libs.androidx.work.runtime)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    // 桩 android.jar 里的 org.json 全是抛异常的空壳，排在真实现前面就白搭；
    // JsonValue 走的就是它，不换掉证书解析那几条用例根本跑不起来。
    testImplementation(libs.json)
}
