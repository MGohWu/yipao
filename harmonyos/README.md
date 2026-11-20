# 壹跑 · HarmonyOS 端

零跑汽车第三方控车 App「壹跑」的 HarmonyOS NEXT 原生版本（ArkTS / ArkUI，Stage 模型）。
App 只与零跑官方服务器通信，不依赖任何第三方自建服务。

> 本项目与零跑汽车没有任何隶属、合作或授权关系。请只用自己的账号控制自己或已获授权的车辆。

## 功能

- **登录**：零跑账号短信验证码登录，会话存于关键资产（Asset Store Kit）。
- **车辆首页**：电量 / 续航（含增程车型的油量与混合续航）、门窗锁状态、胎压、车内温度，
  可选的 3D 车模型（资源来自零跑官方）或轮廓剪影。
- **远程控车**：上锁 / 解锁、车窗、尾门、前备箱、遮阳帘、天窗、鸣笛寻车、哨兵模式等
  （按车型能力码显示）。控车走生物识别 + 操作密码，操作密码可选择加密保存在本机。
- **空调**：温度、风量、模式、内外循环，空调预约。
- **能源**：充电状态与充电上限、充电计划、电池预热。
- **座舱**：舒适座舱（座椅加热通风、方向盘加热、后视镜）、车载冰箱（按车型显示）。
- **里程能耗**：零跑官方按天统计的里程与能耗。
- **车辆位置**：华为地图展示车辆位置、手机位置与距离，地址反查，驻车照片，跳转第三方地图导航。
- **蓝牙钥匙**：基于零跑官方证书的近车蓝牙直连控车（含国密路径）、可选的无感解闭锁。
- **桌面服务卡片**：小 / 中 / 大卡片与锁车卡片，可选「卡片直接控车」。
- **桌面快捷方式**：长按图标开关车锁、鸣笛寻车、开关尾门。
- **其他**：深浅外观、车型信号标定（默认隐藏）、审核演示模式。

所有功能都直接可用，没有会员或付费门槛。

## 开发环境

- macOS / Windows 上的 **DevEco Studio**，带 HarmonyOS SDK **6.1.0(23)**
  （`build-profile.json5` 里的 `targetSdkVersion` / `compatibleSdkVersion`）。
- 运行 `scripts/` 下自检脚本需要 **Node.js 22.7 及以上**（蓝牙 / 座舱等 selftest 依赖
  `--experimental-transform-types`；DevEco 自带的 Node 版本较低，跑不了这几个）。
- 真机调试需要一台 HarmonyOS NEXT 手机，以及一个华为开发者账号（用于自动签名）。

项目没有三方 ohpm 依赖，不需要 `ohpm install`。

## 编译与运行

### 在 DevEco Studio 里

1. 用 DevEco Studio 打开本目录。
2. **签名**：`File → Project Structure → Project → Signing Configs`，登录华为账号后勾选
   「Automatically generate signature」。DevEco 会把生成的证书路径、加密后的密码和
   profile 写进 `build-profile.json5` 的 `signingConfigs`——这些是个人材料，**不要提交**。
3. 连接手机，点运行。

### 命令行

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk          # 按实际安装位置调整
HVIGORW=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw

# 务必先 clean 再全量编译：增量编译只报改动过的文件的警告，容易漏
"$HVIGORW" clean --no-daemon
"$HVIGORW" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

没有配置签名时会跳过签名，产物是 `entry/build/default/outputs/default/entry-default-unsigned.hap`
（只能验证编译，装不上真机）。配好签名后产物为 `entry-default-signed.hap`，可以用
`hdc install -r <hap 路径>` 安装。

`buildMode=release` 会启用 ArkGuard 混淆（规则见 `entry/obfuscation-rules.txt`）。
凡是会落盘、跨进程或发给服务端 / 车端、按字面量取值的属性名，都必须加进 `-keep-property-name`，
否则只有 release 包会出问题。

## 需要自己准备的配置

| 项 | 位置 | 说明 |
| --- | --- | --- |
| 包名 | `AppScope/app.json5` 的 `bundleName`（默认 `org.yipao.app`），以及 `entry/src/main/resources/base/profile/shortcuts_config.json` 里三处 `bundleName` | 自动签名会在你的 AGC 账号下按这个包名建应用。和别人已占用的包名冲突时自行改掉，两处要一致。 |
| 签名 | `build-profile.json5` 的 `signingConfigs` | 开源版为空，见上文「签名」。 |
| 华为地图 `client_id` | `entry/src/main/module.json5` 里 `metadata` 的 `client_id` | 开源版留空。在 AGC 上为你的应用开通 Map Kit，把该应用的 Client ID 填进来；它必须与签名 profile 对应同一个应用。留空时车辆位置页、首页位置缩略图会降级为灰底占位，其余功能不受影响。开通服务后需要重新生成一次签名 profile。 |

### 受限权限 `PERSISTENT_BLUETOOTH_PEERS_MAC`

`module.json5` 申请了 `ohos.permission.PERSISTENT_BLUETOOTH_PEERS_MAC`（system_basic 级受限权限）。
鸿蒙给出的蓝牙 deviceId 是随机地址，系统会定期轮换；这条权限让 App 能把已配对车辆的
随机地址登记下来，地址轮换、App 重启之后仍能直接连接。

**DevEco 自动签名生成的 profile 不带这条 ACL，安装时会报 `9568289`（权限未授予）而失败。** 两种处理方式：

1. 在 AGC 上为应用申请该受限权限，审批通过后用包含这条 ACL 的 profile 手动签名；
2. 自己编译调试时，从 `entry/src/main/module.json5` 的 `requestPermissions` 里删掉这一条。
   App 仍能编译运行，登记随机地址会失败（只记一条诊断日志，不影响当次连接），代价是：
   车辆地址轮换或重启 App 之后，蓝牙钥匙可能连不上已绑定的车，需要重新搜索并绑定；
   无感解锁也会因此中断。

## 测试与自检

鸿蒙端没有 ohosTest 单元测试，回归靠 `scripts/` 下的 Node 脚本：把 `.ets` 源码原样搬到
Node 上跑（只替换系统模块 import），或对资源、配置做静态检查。都只用 Node 内置模块。

```bash
node scripts/contrast-check.mjs                      # 色彩对比度（华为 UX 标准：正文 ≥4.5:1、图标 ≥3:1）
node scripts/static-check.mjs --verbose              # 深浅色资源对齐、配置可解析、混淆白名单、@Monitor 路径
node scripts/ble-selftest.mjs                        # 国密曲线 / SM2 / 蓝牙协议组帧的固定向量
node scripts/ble-auth-transmission-selftest.mjs      # 蓝牙认证异步写入
node scripts/ble-pairing-preparation-selftest.mjs    # 蓝牙手动配对与证书刷新
node scripts/cabin-selftest.mjs                      # 舒适座舱、冰箱、充电、空调预约等指令与信号解析
node scripts/charge-plan-selftest.mjs                # 充电计划缓存与回读
node scripts/widget-selftest.mjs                     # 卡片配置与控车命令
```

任一脚本失败都以非零退出码结束。改色值、加持久化字段或改 `@Monitor` 之后，至少跑一遍
`contrast-check` 和 `static-check`。

`scripts/gen-shortcut-icons.py` 用来从系统符号字体重新生成桌面快捷方式图标（需要 `pip install fonttools`），
不属于测试流程。

## 目录

```
AppScope/                 应用级配置（包名、版本、图标）
entry/src/main/ets/
  core/                   协议、加密（含国密）、网络、模型、存储
  app/                    状态层（VehicleStore）、蓝牙钥匙、卡片数据、定位
  views/                  页面与组件
  widget/                 桌面服务卡片
  formability/            卡片提供方（FormExtensionAbility）
  entryability/           主 UIAbility
entry/src/main/resources/ 资源；rawfile/ 下是 App 内展示的用户协议与隐私政策
scripts/                  自检脚本
```

## 许可证

GPL-3.0。
