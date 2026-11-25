# 自签安装：让小组件和灵动岛真的活下来

未签名的 IPA 装到手机上必须用你自己的证书重签。控车功能重签后一定正常，**真正会坏的是
小组件、锁屏控件和灵动岛**——它们不是靠 App 本体跑的，而是靠三样东西把 App 和扩展进程连起来：

| 东西 | 放在哪 | 重签时最容易出的事 |
| --- | --- | --- |
| **App Group** | 两份 `.entitlements` + 两份 `Info.plist`（`YPAppGroup`） | profile 里没有这个组 → 容器拿不到，卡片永远显示占位数据 |
| **钥匙串共享组** | 两份 `.entitlements` 的 `keychain-access-groups` | 两个 target 不一致 → 扩展读不到登录态，点了没反应 |
| **扩展本身** | `Payload/LeapControl.app/PlugIns/LeapWidget.appex` | 只签了主 App、漏签扩展 → 卡片和灵动岛整体消失 |

灵动岛（Live Activity）还多一条硬要求：**主 App 的 `Info.plist` 必须有
`NSSupportsLiveActivities = true`**（仓库里已经写好）。缺了它 `Activity.request` 直接抛
`unsupportedTarget`，表现就是「按了锁车，没有岛」，而且不报任何错。

---

## 一、前提：必须是付费开发者账号

**免费 Apple ID（Personal Team）不支持 App Groups。** 用它签出来的包能装、能控车，
但桌面卡片、锁屏控件、控制中心按钮、灵动岛会全部失灵——因为这些表面全靠 App Group
在进程之间传数据。想全都正常，只能用付费账号（￥688/年）。

---

## 二、三条必须逐字一致的字符串

仓库默认值：

```
主 App Bundle ID    org.yipao.app
小组件 Bundle ID    org.yipao.app.widget     ← 必须是主 App 的 ID + ".widget"
App Group           group.org.yipao.app
钥匙串共享组        $(AppIdentifierPrefix)org.yipao.app   ← 构建时展开成 <TeamID>.org.yipao.app
```

想换成自己的（推荐，避免和别人的 App ID 撞车）：

```bash
cd ios
python3 scripts/configure-signing.py \
    --team   ABCDE12345 \
    --bundle-id com.你的前缀.yipao \
    --app-group group.com.你的前缀.yipao
xcodegen generate
```

这个脚本会把 6 个文件里的相关字符串一次改齐，并在结尾校验 App Group 四处逐字一致。
**手改的话最容易漏掉 `Info.plist` 里的 `YPAppGroup`**，漏了就是「App 正常、卡片空白」。

---

## 三、开发者后台要做的事（一次，约 5 分钟）

1. **Certificates, Identifiers & Profiles → Identifiers → App Groups → ＋**
   注册上面那个 App Group（例如 `group.com.example.yipao`）。名字必须**完全一致**，
   包括 `group.` 前缀。
2. **Identifiers → ＋** 建两个 App ID（Explicit）：
   - `com.example.yipao`
   - `com.example.yipao.widget`

   两个都要勾上：
   - **App Groups** → 选中刚注册的那个组
   - **Keychain Sharing**（在两个 App ID 上都要开，共享组留默认即可）
3. 建两个 Provisioning Profile（Development 或 Ad Hoc），分别对应这两个 App ID，
   下载后双击导入。

> 只建一个 profile 给主 App 是不够的：扩展是独立的可执行文件，必须有自己那份。

---

## 四、两条签名路径

### A. 用 Xcode 直接装（最省事，推荐）

```bash
cd ios
xcodegen generate
open LeapControl.xcodeproj
```

选中 `LeapControl` target → Signing & Capabilities：

- Team 选你自己；
- 确认 `App Groups` 和 `Keychain Sharing` 两栏都没有红字（红字就是后台没配好）；
- 对 `LeapWidget` target 重复一遍（**两个 target 的 App Group 必须一模一样**）；

插上手机，选真机 Run。装完到「设置 → 通用 → VPN 与设备管理」信任证书，
iOS 16 以上还要打开「设置 → 隐私与安全性 → 开发者模式」。

### B. 用工具给现成的 IPA 重签（Sideloadly / AltStore / ESign / Feather 等）

先把 IPA 做出来（见 `README.md` 的「编译」一节，或直接跑
`ios/scripts/build-ipa.sh`，也可以让 CI 出包）——产物是**不带任何签名**的裸包，
这正是重签工具最想要的输入。

用工具时注意三件事：

1. **不要顺手改 Bundle ID。** 很多工具默认会把它改成「你的前缀 + 原 ID」。一旦改了，
   `.appex` 的 Bundle ID 必须同步改成 `<新 ID>.widget`，而工具通常只改主 App ——
   扩展的 ID 对不上，卡片就装不上。要么不改，要么在工具里把两个一起改。
2. **确认 App Group 真的注入了。** 工具用的是你 profile 里的 entitlements；
   如果 profile 没开 App Groups，签出来的包 entitlements 里就没有这一项，
   表现是「卡片能加、但一直显示占位 / 锁屏控件点了没反应」。
   签完可以用下面的命令自查（先解压 IPA）：

   ```bash
   unzip -o Yipao-iOS-unsigned.ipa -d /tmp/yipao
   codesign -d --entitlements :- /tmp/yipao/Payload/LeapControl.app
   codesign -d --entitlements :- /tmp/yipao/Payload/LeapControl.app/PlugIns/LeapWidget.appex
   ```

   两份输出里的 `com.apple.security.application-groups` 必须都有、且都是同一个字符串，
   `keychain-access-groups` 也必须相同。
3. **扩展必须一起签。** 只签主 App 会得到一个「App 能开，但小组件库里根本没有Leap跑」的结果。

如果工具不肯让你控制这些，退回路径 A（Xcode），或者用付费账号 + Development profile
手动 `codesign` 三层（先签 appex，再签 app，顺序不能反）。

---

## 五、装完怎么确认真的活着

按顺序试，哪一步断了下面对照表查：

1. **桌面小组件**：长按桌面 → 左上角 ＋ → 搜「Leap跑」→ 应该能看到「车辆状态 / 车锁 /
   上锁车辆 / 解锁车辆」四张卡。加上之后**显示的是真实电量**，不是占位灰块。
2. **锁屏控件**：锁屏长按 → 自定义 → 添加「Leap跑」的车锁按钮，按下去能真的开锁。
3. **灵动岛**：App 里按一次锁车/解锁，屏幕顶部应出现一条带车图的岛，进度走完收起。
4. **控制中心 / 操作按钮**：能加到控制中心并生效。

## 六、故障对照

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 小组件库里搜不到「Leap跑」 | 扩展没嵌进 IPA，或扩展没签 | 看 `Payload/LeapControl.app/PlugIns/LeapWidget.appex` 在不在；重签时确保带上扩展 |
| 卡片能加，但一直是占位数据 | App Group 没注入 / 名字不一致 / 没在后台注册 | 用上面 `codesign -d` 查两份 entitlements；核对 `Info.plist` 的 `YPAppGroup`；确认两个 App ID 都勾了 App Group |
| 卡片点按钮没反应，App 里正常 | 钥匙串共享组两边不一致 | 两个 target 的 `keychain-access-groups` 必须相同 |
| 灵动岛从来不出现 | `NSSupportsLiveActivities` 被改掉，或系统设置里关了「实时活动」 | 查主 App `Info.plist`；iPhone「设置 → Leap跑 → 实时活动」打开 |
| 装到一半报 `Mismatched Application Identifier Entitlement` | profile 和 Bundle ID 对不上 | 重签时 Bundle ID 与 profile 绑定的那个保持一致 |
| 装完打不开、闪退 | 证书没信任 / 没开发者模式 / 描述文件过期 | 通用 → VPN 与设备管理里信任；免费账号 7 天过期 |

---

## 七、和「定位偏移」无关的部分

坐标系的问题在源码里已经改好（见 `LeapControl/Core/SignalSchema.swift` 与
`Shared/CoordinateTransform.swift` 的说明），跟签名方式没有任何关系——签谁的包都一样准。
如果只有你自己这台车偏、别人不偏，那不是坐标系，先看车端 GPS 是不是在地库/高楼下面。
