# 壹跑 iOS

零跑汽车第三方控车 App「壹跑」的 iOS 端。SwiftUI 原生实现，iOS 26 上使用液态玻璃，低版本自动降级成毛玻璃；最低支持 iOS 18.2。

本项目与零跑汽车没有任何隶属或授权关系，只使用车主自己的零跑账号访问零跑官方服务。请只控制属于你自己或你已获授权的车辆。

## 功能

- **登录**：零跑账号短信验证码登录，登录态与操作密码只保存在本机钥匙串（仅本设备，不同步、不进备份）。
- **车况**：电量 / 续航（含增程车型油量）、充电状态、门窗锁、尾门、胎压、空调、车辆位置等，前台每 10 秒轮询一次。
- **远程控车**：开关车锁、鸣笛寻车、尾门、车窗、天窗 / 遮阳帘 / 前备箱（按车型能力码显示）、空调（温度 / 风量 / 模式）、远程启停充电、解锁充电枪、哨兵模式等。所有会动车的指令都要先通过 Face ID / 触控 ID 或操作密码验证。
- **功能中心**：侧边操作按钮、锁屏控件、桌面小组件直接控车；蓝牙钥匙（可信车辆绑定、近车直连、无感解闭锁）；电池预热；充电计划；舒适座舱（座椅加热 / 通风、方向盘加热、后视镜加热）；车载冰箱；预约空调。
- **桌面卡片与锁屏控件**：多种尺寸的车况小组件、锁屏车锁 / 鸣笛控件、控车过程的灵动岛（Live Activity）、长按图标快捷操作。
- **车辆位置**：地图显示车辆与本机位置，可跳转苹果 / 高德 / 百度 / 腾讯地图导航，显示最近一张驻车照片。
- **服务**（底部第四个 Tab）：
  - **行程记录**：逐趟记录每次出行的起止、里程、耗电与平均时速。
  - **充电记录**：逐次记录充电地点、起止电量、充入度数、峰值功率与快慢充类型。
  - **里程能耗**：零跑官方的按天 / 按周聚合统计。
  - 前两项由 App 自己按轮询切段（见「记录是怎么来的」），第三项来自官方接口。
- **后台记录**（设置 → 后台记录，默认关闭）：用低精度持续定位把进程拖住，锁屏后仍按 60 秒一次读车况，行程和充电不会因为 App 退到后台而断。代价是耗电增加、状态栏出现定位图标，所以做成开关，默认不开。
- **演示模式**：登录页提供演示账号（手机号 `13800138000`、验证码 `000000`），使用写死的模拟车况，不发任何网络请求、不会向任何车辆下发指令。

## 开发环境

- macOS + Xcode 26（正式版），iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 真机调试需要一个 Apple 开发者账号（免费账号也可以装到自己的设备上，但 App Groups 等能力受限）

第三方依赖只有 `Vendor/GmSSL/GmSSL.xcframework`（国密 SM2 / SM3 / SM4，用于新款车型的蓝牙钥匙认证），已随仓库提供，许可证见同目录下的 LICENSE 文件。

## 目录结构

```text
project.yml        XcodeGen 工程描述（.xcodeproj 由它生成，不入库）
LeapControl/
  App/             全局状态（VehicleStore）、入口、蓝牙控制器、演示数据
  Core/            鉴权、签名、网络、车况解析、蓝牙协议、国密封装（无 UI 依赖）
  DesignSystem/    背景、玻璃卡片、配色
  Features/        各个页面
  Shared/          App 与小组件共用的快照、偏好、App Intents、Live Activity
  Legal/           App 内展示的用户协议与隐私政策
LeapWidget/        小组件扩展（桌面卡片、锁屏控件、灵动岛）
LeapControlTests/  单元测试（签名对拍、车况字段语义、蓝牙协议、会话并发等）
Vendor/GmSSL/      GmSSL 预编译库
```

## 编译前要自己准备的配置

| 配置 | 位置 | 说明 |
| --- | --- | --- |
| Apple Team ID | `project.yml` 里的 `DEVELOPMENT_TEAM` | 仓库里留空。只在模拟器上跑可以不填；装真机必须填你自己的 Team ID，或者生成工程后在 Xcode 的 Signing & Capabilities 里选择。 |
| Bundle ID | `project.yml` 各 target 的 `PRODUCT_BUNDLE_IDENTIFIER` | 默认 `org.yipao.app`（主 App）、`org.yipao.app.widget`（小组件）、`org.yipao.app.tests`。Bundle ID 全局唯一，用自己的账号签名时多半要改成你自己的前缀。 |
| App Group | 两份 `.entitlements`、两份 `Info.plist` 的 `YPAppGroup`、`VehicleSnapshot.swift` 里的兜底常量 | 默认 `group.org.yipao.app`。**四处必须一致**，还要在开发者后台注册并在两个 App ID 上都勾上。 |
| 钥匙串共享组 | 两份 entitlements 里的 `keychain-access-groups` | 默认 `$(AppIdentifierPrefix)org.yipao.app`，App 与小组件必须相同。 |
| 高德 Web 服务 key | `LeapControl/Info.plist` 的 `AMapWebKey` | 可选。**只影响「驾车距离」**，不填就退回苹果 MapKit，见下面「驾车距离」。 |

上面这几项不要手改——**一条命令改齐**：

```bash
cd ios
python3 scripts/configure-signing.py --team ABCDE12345 \
    --bundle-id com.example.yipao --app-group group.com.example.yipao \
    --amap-key 你的高德key
```

它会改完 6 个文件并校验 App Group 四处逐字一致。自签之后小组件和灵动岛怎么才能不掉，
见 [`SIGNING.md`](SIGNING.md)。

地图本身用的是系统 MapKit，不需要地图 SDK key；只有「距离」这一个数字要问高德。

### 这一格该算步行还是驾车

**找自己的车，人是走过去的。** 底下那个「导航到车辆」按钮一直就是按步行打开的
（`MKLaunchOptionsDirectionsModeWalking`），所以旁边这一格也应该是步行——曾经显示驾车，
于是出现「我就在路口，它说开车 1.3 公里」这种看着像 bug 的荒谬数字。

差别有多大：实测江门江华一路一带同一对点，**直线 334 米，步行 363 米，驾车 1486 米**
（车开不进巷子，得绕到东华一路再回来）。两个数都对，但只有一个回答了用户的问题。

所以按直线距离自动选（`TravelMode.preferred(forStraightDistance:)`）：

| 直线距离 | 这一格显示 |
|---|---|
| ≤ 2 公里（约 25 分钟步行） | 「步行距离 · 高德」 |
| > 2 公里 | 「驾车距离 · 高德」 |

判据只用本地算出的直线距离，不依赖任何网络结果，所以算路之前就定了。

### 这个数问谁要

三端原本各问各的：安卓走高德 SDK（`RouteSearchV2`）、鸿蒙走华为 Petal
（`navi.getDrivingMatrix`），只有 iOS 用 `MKDirections`。坐标口径统一之后，
剩下的差异全在「谁来算这条路」上——苹果在大陆的路线引擎面对老城路网会给出更长的一条
（绕开小路、多一个掉头），同一对起终点比高德多出几百米很常见，表现就是
**车标位置和直线距离都对，唯独驾车距离偏大**。

所以 `DrivingRouteService` 只在**配了高德 key** 时才取这个数：

- 有 `AMapWebKey` → 步行走 `v3/direction/walking`、驾车走 `v3/direction/driving`，
  多条方案取最短，和安卓端同一套数据；位置卡上显示「步行距离 · 高德 · N 分钟」。
- 没配 key → **这一格根本不显示**，位置卡上只剩「直线距离」。
  连请求都不发。不是「显示一个差不多的数」——苹果那个偏大的数摆上去，
  车主一跟高德比就会以为定位又偏了，比不显示更糟。要开过去，点「导航到车辆」
  就有准确的路线和耗时。
- 配了 key 但这一次请求失败 → 退回 `MKDirections`（`requestsAlternateRoutes = true`
  之后自己取最短），实在拿不到才显示「暂不可用」。

key 在 [高德开放平台](https://console.amap.com) 申请：应用管理 → 新建应用 → 添加 Key，
**服务平台选「Web服务」**。个人开发者免费，需要实名认证。这一步完全可选——
不配只是少一格数字，其它功能一概不受影响。

实际用的是哪个模式、哪个源，都会写进 App 内的诊断日志
（`[route] 步行距离 892m/318s 来源=高德`，在「蓝牙钥匙 → 蓝牙诊断」里看）。
失败也会写明原因，比如 `高德步行距离无可用路线 http=200 status=0 info=... code=10003`——
不然「配了 key 数字没变」只能靠猜。

改完配置后重新执行一次 `xcodegen generate`。

### 手机那一侧也要转一次

车标是 GCJ-02，手机不是。`CLLocationManager` 在大陆吐的是 GPS 原始坐标（WGS-84），
和地图底图差 300~800 米——**但地图上那个系统蓝点一直是准的**，因为 MapKit 在画蓝点的
时候自己纠了偏。这一点很容易让人误以为「CoreLocation 给的也是 GCJ-02」，于是手机的坐标
就那么原样用了（1.6 及之前就是这样）。

后果不是整页偏，而是**只有跟手机有关的量偏**：

| 现象 | 原因 |
|---|---|
| 按右上角定位按钮，屏幕中心落在半条街外 | 相机拿 WGS-84 落点对 GCJ-02 底图 |
| 直线距离比实际多出四五百米 | 一边 GCJ-02、一边 WGS-84 直接相减 |
| 高德算出来的距离怎么调都不对 | 起点被当成 GCJ-02 传给了高德 |

现在 `UserLocationProvider.coordinate` 是唯一出口，出来就已经是 GCJ-02，
地图、直线距离、步行/驾车判据、算路起点全用它。诊断日志里能直接看到这次换算挪了多少：
`[phone] 精度12m 换算512m`——大陆范围内这个数固定几百米，如果是几十米或几公里，那才是
信号问题。

## 编译与运行

```bash
xcodegen generate
open LeapControl.xcodeproj
```

在 Xcode 里选择 `LeapControl` scheme 和目标设备运行即可。命令行编译：

```bash
# 模拟器
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 4 build

# 真机（需要已填 Team ID，并在 Xcode → Settings → Accounts 登录 Apple ID）
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'id=<设备 UDID>' -allowProvisioningUpdates build
```

首次装到真机后，可能需要在 iPhone 的「设置 → 通用 → VPN 与设备管理」里信任开发者证书。

### 只出一个未签名的 IPA（给 Sideloadly / AltStore 用）

```bash
cd ios
./scripts/build-ipa.sh            # 产物：ios/build/Yipao-iOS-unsigned.ipa
```

脚本会先 `xcodegen generate`，再以 `CODE_SIGNING_ALLOWED=NO` 打包 `Release` 归档，
把扩展一起塞进 `Payload` 并校验 `NSSupportsLiveActivities` 与 `PlugIns/LeapWidget.appex`。
没有 Mac 的话，仓库根目录的 `.github/workflows/build-ipa.yml` 可以在 GitHub 的 macOS
runner 上跑同一套流程，产物从 Actions 的 Artifacts 下载。

签名步骤、以及重签后为什么小组件会失效、怎么查，见 [`SIGNING.md`](SIGNING.md)。

### 本地预览（仅 Debug）

没有零跑账号时，可以用演示数据把界面跑起来：

```bash
xcrun simctl launch booted org.yipao.app -demo
```

再加 `-screen <名字>` 可以直接打开指定页面，例如 `climate`、`charge`、`map`、`settings`、`trips`、`tires`、`trunk`、`password`、`widget`、`widgetlarge`、`widgetlock`、`cabin`、`fridge`、`features`。

## 跑测试

```bash
xcodegen generate
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 4 test
```

说明：

- 测试用 Swift Testing 编写，部分用例会真实读写钥匙串和 App Group，**不要加 `CODE_SIGNING_ALLOWED=NO`**，否则这些用例会整片假失败。模拟器上不填 Team ID 也能跑（Xcode 会用 "Sign to Run Locally"）。
- `-jobs 4` 是为了限制并行编译，避免把 CPU 吃满导致模拟器不稳定，可按机器情况调整。
- 改动 `Core/Crypto.swift`、`Core/LeapClient.swift` 里的签名逻辑后务必跑测试：签名错误时服务端只会回一句笼统的校验失败，没有任何定位信息。

## 实现要点

- **两条鉴权链路**：老链路（`appuser.leapmotor.cn`）负责短信登录和远控下发，参数按 key 升序拼接后签名；新网关（`app-gw-global-master.leapmotor.com`）负责车辆列表、路由和车况，固定请求头 + 业务参数做 HMAC-SHA256。两条链路各自续期，缺一条都用不了。
- **操作密码**：用老 token 派生 key / iv，AES-128-CBC 加密后随指令发送。生物识别只是取出本机已保存密码的钥匙，不能替代它。
- **车况字段**：车端 `signalMap` 的字段语义按车型分为两套口径，详见 `Core/SignalSchema.swift` 里的注释；读不到的车况一律不显示，不回退默认值。
- **蓝牙钥匙**：老款证书走 `keyType=0`（P-256 ECDH / SHA-256 / AES），新款国密证书走 `keyType=1`（SM2 KAP / SM3 / SM4）。
- **钥匙串分组必须带 Team ID 前缀**：entitlement 里是 `$(AppIdentifierPrefix)org.yipao.app`，真机上会展开成 `<TeamID>.org.yipao.app`；查询时只传不带前缀的名字会静默失败。`SessionStore` 里的 `KeychainSharing` 通过探测拿到真实前缀。

## 记录是怎么来的

零跑云端**没有逐趟行程、也没有逐次充电的明细接口**。`drivingrecord` 命名空间下只有按天 / 按周的里程能耗聚合（`mileage/energy/detail`、`getLastweekEC`…），官方 App 的「行程」页也只到「天」。所以这两份记录只能由 App 在运行时按 10 秒一次的车况轮询自己切段，判定逻辑分别在 `Core/TripLog.swift` 和 `Core/ChargeLog.swift`，都是纯逻辑、可单测。

行程：

- 挡位报 D/R 开始；连续 3 帧（30 秒）停稳且里程表不动收尾，所以等红灯、临时下人不会切段。
- 短于 300 米丢弃（挪车位、洗车）。
- 距离取「里程表差」与「轨迹累加」里大的那个：里程表是整数公里，短途不跳字；轨迹走折线略偏小。

充电：

- **只有真的在充才开会话**：`1149 == 1`，或读不到该信号时功率 ≥ 0.5 kW。插枪待充、预约等待（`1149 == 4`）不算——否则会记出一条 0 度电的充电。
- 插枪维持会话：墙盒负载均衡断电几十秒不会把一次充电切成五六段。
- 车报「本次充电已结束」（`1149 == 2`）满 3 帧收尾，所以充完不拔枪不会挂一整晚。
- 电量按「电压 × 电流」随时间积分，单步封顶 60 秒；读不到电压电流的车型退回「SoC 差 × 学习值」。
- 每 1% 电量对应多少度是**学出来的**（`ChargeRecorder` 用 0.7/0.3 指数平滑），不是写死的电池容量，所以补记也有度数可给。

两者共同的限制：**App 没在运行时看不到车**。两帧间隔超过 10 分钟时，记录会收在断档前那一帧，再用里程表差 / 电量差补一条标着「补记」的记录。界面上必须说清这一点，漏记不是 bug。

### 后台记录：为什么需要一条定位

默认情况下 iOS 只给两种后台能力：`bluetooth-central`（蓝牙钥匙要它）和几秒钟的收尾时间。退到后台几秒后进程被挂起，`Task.sleep` 停住，10 秒一次的轮询随之断掉——这就是「补记」的来源。

想让轮询在锁屏后继续，唯一正当的办法是**持续定位**：`UIBackgroundModes` 里声明 `location`（见 `Info.plist`），用精度 3 公里、位移 500 米才上报的定位更新把进程拖着。这个定位**不用来画轨迹**——轨迹来自车机 GPS，比手机准得多；它在这里唯一的作用是「别让进程睡过去」。实现见 `App/BackgroundKeeper.swift`。

三件事必须同时成立，缺一样都会**静默失效**（不报错，只是进后台就断）：

1. `Info.plist` 的 `UIBackgroundModes` 含 `location`；
2. `allowsBackgroundLocationUpdates = true`，而且**只能在 App 处于前台时设置**——在后台赋值会直接抛 `NSInternalInconsistencyException`；
3. 定位权限是「始终允许」。只有「使用期间」时，锁屏立刻失效。

第 3 条最容易踩，所以 `BackgroundKeeper.Status` 把「只有使用期间」单独分成 `needsAlways`，设置页据此给出能照做的提示，而不是笼统说一句权限不足。

节奏由 `Core/RecordingPolicy.swift` 统一决定，不在 View 里散着写：前台 10 秒，后台 60 秒，开关关着就不轮询。后台不再放大间隔的话，一天是 8600 次云端读请求；放得再大（比如 5 分钟）就会让「连续 3 帧停稳收尾」拖到 15 分钟——那时候该改的是判定逻辑（按时间而不是按帧数），不是调常量。

两个副作用写在这里，免得以后当成 bug 查：

- 后台一帧 60 秒，所以切段判定的粒度比前台粗：停稳收尾约 2~3 分钟，而不是前台的 30 秒。
- 后台不再每帧请求卡片重载（`publishSnapshot` 里三分钟放一次）。WidgetCenter 对 timeline 重载有预算，戳太勤会被降权，等到真该刷的时候反而刷不出来。

## 许可证

GPL-3.0。`Vendor/GmSSL` 下的第三方组件沿用各自的许可证（Apache-2.0 / MIT）。
