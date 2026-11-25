# 交接说明（HANDOFF）

> 写于 2026-11-25 21:42。给「换一台电脑继续」或者「隔几天回来」的自己看。
> 代码和产物都在 GitHub，**不依赖任何一台本地机器**；本地只有对话记录。

## 一、现在到哪了

| 项 | 值 |
| --- | --- |
| 应用名 | Leap跑（`CFBundleDisplayName`，App 与小组件同名） |
| 当前版本 | 2.9 / `CURRENT_PROJECT_VERSION` 见 `ios/project.yml` |
| 最新产物 | `Leap跑-2.9-unsigned.ipa`（约 2.50 MB） |
| sha256 | `f11698ad073a1e8d02c17d1b71a4f37e774e4ae5705d59cda39ebfd635cd1483` |
| 最近跑通的流水线 | 单测 `45623629087` / 打包 `45623633655` |

包名 `app.silver9175.tomato8924`，未签名，用 Sideloadly / AltStore / ESign 自己签。

## 二、电脑关机后怎么继续出包

**不需要这台电脑。** 测试和打包都跑在 GitHub Actions 的 macOS 机器上。

手机上就能做：

1. 浏览器打开 `https://github.com/MGohWu/yipao/actions`
2. 左边选 **Build unsigned IPA** → 右边 **Run workflow** → 分支 `main` → 绿色按钮
3. 等 5～8 分钟（排队时更久）
4. 回到这条 run 的页面，最下面 **Artifacts** → 下载 `Paopao-iOS-unsigned`
5. 解压得到一个叫 `跑跑-iOS-unsigned.ipa` 的文件（文件名是构建脚本里写死的，与应用显示名无关）
6. 用签名工具装上

跑单测同理：**Unit tests** → Run workflow，`only` 留空跑全量。

## 三、本地开发（换电脑后）

```bash
git clone https://github.com/MGohWu/yipao.git
cd yipao/ios
brew install xcodegen
xcodegen generate        # 生成 LeapControl.xcodeproj（不入库）
open LeapControl.xcodeproj
```

- 部署目标 iOS 18.2，用 Xcode 26 编译
- 第三方依赖只有 `Vendor/GmSSL/GmSSL.xcframework`，已随仓库提供
- 签名相关见 `ios/SIGNING.md`

## 四、已知问题（重要，别重复踩）

### 1. 国区拿不到官方逐趟行程/充电明细

**结论**：`POST {appCenter}/carownerservice/mileage/daily/detail/page` 对国区账号返回
`{code:-1, data:null, message:"发生错误"}`；`charge/daily/detail/page` 通但恒 0 条。
而两个接口的「可用性探测」`…/vail/startTime/query` 都回 `code=0`——说明命名空间存在、
签名鉴权全对，是服务端不给我们数据。

**证据链**：

- 试过 8 种入参形态（秒 / 毫秒 / 日期 × 数字 / 字符串分页 × pageSize 20 / 50 × 带不带 timeZone），全 -1
- 试过 3 条路径（含 `v3/api/drivingrecord/…`）、3 种车身号字段（`vin` / `carvin` / `carVin`）
- 国区第三方项目 `leapmotor-mate-cn` 的 `docs/CHINA-MARKET.md` 明写：
  「官方逐筆行程／充電歷史匯入｜尚未支援；不能用每日能耗假造逐筆行程」

**已经做的处理**（`Core/LeapClient.swift`、`App/TripRecorder.swift`）：探测收敛到 3 条路径 × 3 种形态，
成功就记住、失败连败 3 次后改为一天试一次；界面不再挂服务端原话，改成一句
「官方明细暂不可用，下面的记录都来自本机」。

**如果以后要再试**：唯一有依据的办法是抓官方 App 的包（Stream / Charles + 证书），
看它到底打哪个 host、path、body。没有抓包就不要继续猜参数。

### 2. 3D 车模不能用 `.realistic` 地图样式 / 高程

首页车模是 WebView 渲的，地图（位置页）必须用平面 `.standard`：国内高程数据覆盖不全，
用 3D 样式的地方会整屏空瓦片。

### 3. 构建脚本必须是 LF 行尾

用脚本改 `.yml` / `.sh` 时如果写成 CRLF，GitHub runner 会报
`env: bash\r: No such file or directory`（exit 127）。改完用 `open(p,'wb')` 写回。

## 五、代码地图

| 文件 | 管什么 |
| --- | --- |
| `DesignSystem/LeapStyle.swift` | 全部视觉令牌：配色、圆角、`LeapBackground`（MeshGradient 极光）、`GlassCard` |
| `DesignSystem/LeapGlass.swift` | iOS 26 液态玻璃 / 18~25 毛玻璃降级 |
| `Features/HomeView.swift` | 首页：车图展台（`VehicleHero.stage`）、里程/温度卡、状态条 |
| `Features/QuickControlBar.swift` | 首页控制条：圆形按钮、绿底高亮、长按拖拽排序 |
| `Features/VehicleLocationView.swift` | 位置页：全屏地图 + 上下渐隐 + 底部浮卡 |
| `Features/ServicesView.swift` | 服务页：本周概览 + 三个入口 |
| `Features/RecordsKit.swift` | 记录页公共件：分段控件、汇总 hero、标签、同步状态行 |
| `Features/TripHistoryView.swift` | 行程记录（云端 + 本机 + 补记合并） |
| `Features/ChargeHistoryView.swift` | 充电记录（同上） |
| `Core/CloudTripLog.swift` | 云端逐趟记录解析与合并（`CloudTripMerge`） |
| `Core/CloudChargeLog.swift` | 云端充电记录解析与合并（`CloudChargeMerge`） |
| `Core/TripLog.swift` | 本机切段状态机（`TripTracker`）：60 秒 + 熄火 + 插枪 |
| `Core/ChargeLog.swift` | 本机充电切段（`ChargeTracker`） |
| `Core/LeapClient.swift` | 全部云端接口，含签名、旧的 drivingrecord、云端历史（多形态探测） |

## 六、下一步可以做的

1. **抓包后再试一次云端明细**（有依据才做，见上）
2. 充电记录也接云端统计接口（`charge/statistic/days` 是通的，能对账）
3. 桌面小组件跟着新配色重画一版
4. 设置页还留着旧的圆角/间距，没跟 2.7 的设计令牌对齐

## 七、只有手机、没有电脑的时候（2026-11-25 补）

### 能做的：照常出包

打包和测试都在 GitHub 的机器上跑，手机浏览器就够了：

1. `https://github.com/MGohWu/yipao/actions`
2. 左边 **Build unsigned IPA** → 右边 **Run workflow** → `main` → 绿色按钮
3. 等 5～8 分钟（排队时更久）
4. 这条 run 页面最下面 **Artifacts** → 点 `Paopao-iOS-unsigned` 下载
5. 手机上会拿到一个 zip：用「文件」App 解压，里面是 `跑跑-iOS-unsigned.ipa`

### 能做的：手机上签名安装

- 用自己的 Apple ID 在 ESign / 轻松签这类工具里签（个人证书 7 天有效，到期重签）
- 不要用来源不明的企业证书：随时被吊销，而且是把设备交出去了
- 装完第一次打开要信任证书：设置 → 通用 → VPN与设备管理

### 不能做的：改代码

改代码需要一个能跑 WorkBuddy 的桌面环境（Windows / macOS）。云电脑可以：

- 租一台 Windows 云桌面（按小时计费那种），装 WorkBuddy、登录同一账号，`git clone` 仓库
- 这个对话不会自动搬过去——**上下文在 `HANDOFF.md` 里**，把文件丢给新的会话说「继续」即可
- 云电脑不需要是 Mac：iOS 的编译签名全在 GitHub Actions 上，本地只要能 git + 跑 WorkBuddy

### 一句话

**出包不需要电脑，改代码需要。** 手机能做的上限就是触发构建、下载、签名、安装。

## 八、手机上直接拿到 2.9 的产物

最近一次成功的打包（提交 `00d7ae97`，就是 2.9 那一版）：

- run 页面：`https://github.com/MGohWu/yipao/actions/runs/45623633655`
- 页面最下面 **Artifacts** → `Paopao-iOS-unsigned`（约 2.4 MB）
- 下载后是个 zip，解压得到 `跑跑-iOS-unsigned.ipa`
- 该 artifact 保留到 2026-12-25

想打新版本就按第七节重新点一次 **Run workflow**。


## 九、通知提醒（2.10）

三个提醒：**未锁车超时**（默认 10 分钟，可在设置里改 5/10/20/30）、**开始充电**、**充电完成**。

- 判定在 `Core/VehicleAlerts.swift`（纯逻辑，11 条单测），投递在 `App/AlertCenter.swift`。
- 规则细节：
  - 未锁车：车没在开 + 锁状态**明确**是未锁，持续到时限才提醒一次；锁上即复位。
    读不到锁状态（`nil`）不提醒——那可能只是信号没上报。
  - 开始充电：连续两帧确认，挡掉功率抖动；**冷启动时已经在充不提醒**（否则每次打开 App 都弹一条假的「开始充电」）。
  - 充电完成：从在充变不在充，且车说 `1149 == 2` 或枪还插着；拔枪走人不提醒。
- **为什么不是远程推送**：原厂是 APNs + 厂商自己的服务端，注册 token 的接口没有公开资料
  （两个参考项目都没有），证书也在厂商手里。第三方要做真推送，得自建服务器接 APNs、
  并且把车主账号密码放在服务器上轮询——代价比收益大，所以做成手机侧本地通知。
  代价是 App 必须还在跑：**打开「后台记录」**（低精度定位保活，60 秒一帧）才能在锁屏后收到；
  把 App 从后台划掉就一条都不会来。
- 权限：第一次打开开关时才请求（不在启动时弹）。开关状态存 App Group，按类别各一个键。
