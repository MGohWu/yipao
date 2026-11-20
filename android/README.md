# 壹跑 · Android

零跑汽车的第三方控车 App（Android 端），Kotlin + Jetpack Compose。用你自己的零跑账号登录，直接与零跑官方服务器和车辆通信，不经过任何第三方服务器。

> 本项目与零跑汽车没有任何隶属、合作或授权关系，不是官方产品。请只用于你自己拥有或已获授权的车辆，远程操作车辆的后果由操作者自行承担。

## 功能

- **登录**：手机号 + 短信验证码登录零跑账号；另有不联网的演示模式（演示账号见 `app/ReviewDemo.kt`）。
- **首页车况与控车**：电量 / 续航 / 门窗 / 胎压 / 车内温度等车况，闭锁解锁、空调、车窗、尾门、鸣笛，以及按车型开放的天窗、遮阳帘、前备箱、哨兵模式。
- **空调与预约空调**、**能源与充电状态**。
- **车辆位置**：高德地图显示车辆与手机位置、直线 / 驾车距离、驻车照片，一键跳转第三方地图导航到车。
- **行程**：零跑官方的里程与能耗统计（近几周百公里电耗、能耗构成、近 7 天里程）。
- **舒适座舱**：座椅加热 / 通风、方向盘加热、后视镜加热；**车载冰箱**（按车辆能力显示）。
- **电池预热**（立即 / 预约）、**充电计划**（目标电量、健康充电、预约时段与循环日）。
- **蓝牙钥匙**：近车直连控车，前台服务常驻的无感解闭锁（支持 P-256 与国密 SM2/SM4 两套协议）。
- **桌面小组件**（小 / 中 / 大车况卡、车锁卡）、**快捷设置磁贴**（车锁、鸣笛）、**常驻通知控车按钮**；可选「直接控车」。
- **指纹 / 人脸**代替手输操作密码；外观（浅色 / 深色 / 跟随系统）、3D 车模显示等设置。

## 开发环境

- Android Studio（需支持 AGP 9.1）或纯命令行
- JDK 17 及以上（Gradle 运行和编译目标均为 17）
- Android SDK：`compileSdk = 37`（Platform `android-37.0`），`targetSdk = 36`，`minSdk = 31`（Android 12）
- Gradle 由仓库自带的 wrapper 下载（9.3.1），不需要单独安装
- 只打 `arm64-v8a`，模拟器请用 arm64 镜像

## 需要自己准备的配置

所有本机配置都放在工程根目录，均已在 `.gitignore` 中，不要提交。

### 1. `local.properties`

```properties
sdk.dir=/path/to/Android/sdk
# 高德地图 Android Key（在高德开放平台申请，绑定你自己的包名和签名 SHA1）
AMAP_KEY=你的高德key
```

- `sdk.dir`：Android Studio 打开工程时会自动生成；命令行编译需手动写，或设置 `ANDROID_HOME`。
- `AMAP_KEY`：编译期注入 Manifest。不填也能编译和运行，只是地图鉴权失败、显示黑图，其他功能不受影响。

### 2. `keystore.properties`（可选，正式签名）

```properties
storeFile=/绝对或相对工程根目录的路径/release.jks
storePassword=keystore 密码
keyAlias=key 别名
keyPassword=key 密码
```

- 有这个文件：`release` 用它签名。
- 没有这个文件：`release` 自动回退到本机的 debug 签名，保证能直接编译出 release 包，但**这种包不要拿去发布**。

### 3. 应用 ID

`applicationId` / `namespace` 为 `org.yipao.app`。如果要自行发布，建议改成你自己的包名（`app/build.gradle.kts`），并用新包名去高德申请 key。

## 编译与运行

```bash
# Debug 包
./gradlew :app:assembleDebug
# 安装到已连接的设备 / 模拟器
./gradlew :app:installDebug

# Release 包（R8 压缩混淆；没有 keystore.properties 时用 debug 签名）
./gradlew :app:assembleRelease
```

产物在 `app/build/outputs/apk/` 下。也可以直接用 Android Studio 打开工程根目录运行 `app` 配置。

说明：debug 包不做证书固定（方便抓包调试），release 包对零跑官方域名（`*.leapmotor.com`、`*.leapmotor.cn`）启用 SSL Pinning。

## 测试

单元测试都是纯 JVM 用例（协议帧、国密 / ECDH、签名、车况解析、小组件状态等），不需要设备或模拟器：

```bash
./gradlew :app:testDebugUnitTest
```

报告在 `app/build/reports/tests/testDebugUnitTest/index.html`。

完整校验：

```bash
./gradlew --console=plain :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease
```

## 目录结构

```
app/src/main/java/org/yipao/app/
├── core/     协议与数据层：零跑接口客户端、签名与加密、车况模型、蓝牙协议、会话存储
├── app/      运行时：VehicleStore（全局状态与控车流程）、蓝牙钥匙控制器、前台服务、演示数据
├── ui/       Compose 界面：导航、各页面、液态玻璃组件、主题
└── widget/   桌面小组件、快捷设置磁贴、后台刷新
app/src/main/assets/legal/   App 内的用户协议与隐私政策
app/src/test/                单元测试
```

## 许可证

GPL-3.0。
