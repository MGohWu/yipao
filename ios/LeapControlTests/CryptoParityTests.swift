import UIKit
import AppIntents
import Foundation
import Testing
@testable import LeapControl

struct DirectControlDefaultTests {
    @Test func installationAndUpgradeEnableOnceThenPreserveUserChoice() throws {
        for previous in [nil, false, true] as [Bool?] {
            let suite = "DirectControlDefaultTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            if let previous { preferences.set(previous, forKey: "widgetControlEnabled") }

            #expect(SharedSettings.migrateDirectControlDefault(in: preferences))
            #expect(preferences.bool(forKey: "widgetControlEnabled"))
            #expect(!SharedSettings.migrateDirectControlDefault(in: preferences))
            preferences.set(false, forKey: "widgetControlEnabled")
            #expect(!SharedSettings.migrateDirectControlDefault(in: preferences))
            #expect(!preferences.bool(forKey: "widgetControlEnabled"))
        }
    }

    @Test func lockScreenActionsRequireDeviceAuthentication() {
        #expect(LockOnlyControlIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(UnlockControlIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }
}

struct WidgetButtonConfigurationTests {
    @Test func draggingPreservesTheRelativeOrderOfOtherButtons() {
        let actions: [WidgetAction] = [.lock, .unlock, .horn, .trunk]
        #expect(WidgetButtonLayout.moving(actions, from: 0, to: 3) == [.unlock, .horn, .trunk, .lock])
        #expect(WidgetButtonLayout.moving(actions, from: 3, to: 0) == [.trunk, .lock, .unlock, .horn])
        #expect(WidgetButtonLayout.moving([.lock, .unlock], from: 1, to: 0) == [.unlock, .lock])
        #expect(WidgetButtonLayout.moving(actions, from: -1, to: 2) == actions)
        #expect(WidgetButtonLayout.moving(actions, from: 2, to: 2) == actions)
    }

    @Test func settingsNormalizeAndPreserveOrder() {
        #expect(WidgetButtonLayout.normalize([], small: false) == WidgetButtonLayout.defaults)
        #expect(WidgetButtonLayout.normalize(["unlock", "invalid", "unlock", "lock"], small: true) == [.unlock, .lock])
        #expect(WidgetButtonLayout.normalize(["unlock", "invalid", "unlock"], small: false) == [.unlock, .toggleLock, .toggleClimate, .trunk])
        #expect(WidgetButtonLayout.replacing([.lock, .unlock, .horn, .trunk], at: 0, with: .unlock) == [.unlock, .lock, .horn, .trunk])
    }

    @Test func explicitDirectionsSurviveEveryLockStateAndDeepLink() {
        for locked: Bool? in [true, false, nil] {
            var snapshot = VehicleSnapshot.placeholder
            snapshot.isLocked = locked
            #expect(WidgetControlRunner.command(for: .lock, snapshot: snapshot, desiredLock: false).expectation == .locked(true))
            #expect(WidgetControlRunner.command(for: .unlock, snapshot: snapshot, desiredLock: true).expectation == .locked(false))
            #expect(ControlActivityAction(.lock, desiredLock: false, snapshot: snapshot) == .lock)
            #expect(ControlActivityAction(.unlock, desiredLock: true, snapshot: snapshot) == .unlock)
        }
        #expect(WidgetAction(deepLink: WidgetAction.lock.deepLink) == .lock)
        #expect(WidgetAction(deepLink: WidgetAction.unlock.deepLink) == .unlock)
    }
}

/// 这些期望值来自 `demo/src/leapmotor-cn-sdk.js` 在同一组输入下的输出。
/// 签名算法只要有一个字节对不上，服务端就会返回 result=39，而且报错信息没有任何指向性，
/// 所以这里锁死已验证过的向量。
struct CryptoParityTests {

    /// 老链路 token：需要 ≥64 字符才能派生 oppwd 的 key/iv。
    private let token =
        "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        + "0f9e8d7c6b5a49382716f5e4d3c2b1a0"
        + "ffee0011223344556677889900aabbcc"

    private let accessToken =
        "eyJhbGciOiJIUzI1NiJ9"
        + ".eyJleHAiOjE3NTQyNTIwMDAsInVzZXJfbmFtZSI6ImRlbW8ifQ"
        + ".q83vASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4k"

    private var r2: String { Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString() }
    private var r3: String { Data("fedcba9876543210fedcba9876543210".utf8).base64EncodedString() }

    private var signHeaders: [String: String] {
        [
            "acceptLanguage": "zh-CN",
            "channel": "1",
            "deviceId": "abc123deviceid",
            "deviceType": "android",
            "nonce": "4242424",
            "source": "leapmotor",
            "timestamp": "1754251200000",
            "version": "1.22.87"
        ]
    }

    @Test("短 MD5 取 hex 的 [8,24)")
    func shortMD5() {
        #expect(LeapCrypto.shortMD5("hello-leapmotor") == "de439bf61241ccf0")
    }

    @Test("签名串按 key 升序拼接 value")
    func concatenation() {
        let params: [String: String] = [
            "cmdid": "110",
            "state": #"{"value":"lock"}"#,
            "carvin": "LP0DEMO0000012086",
            "nonce": "4242424",
            "timespan": "1754251200000",
            "deviceID": "abc123deviceid",
            "token": token
        ]
        let expected = "LP0DEMO0000012086110abc123deviceid4242424"
            + #"{"value":"lock"}"#
            + "1754251200000" + token
        #expect(LeapCrypto.sortAndConcatValues(params) == expected)
        #expect(LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(params)) == "f6035b89f615720a")
    }

    @Test("多个字典合并后再排序，头和业务参数一起参与签名")
    func mergedConcatenation() {
        let body = ["identifier": "9988776655", "identifierType": "1", "security": token]
        let base = LeapCrypto.sortAndConcatValues(signHeaders, body)
        #expect(base == "zh-CN1abc123deviceidandroid998877665514242424"
                + token + "leapmotor17542512000001.22.87")
        #expect(LeapCrypto.sha256Hex(base)
                == "8258cb88dc30248cb83db4c131291ea0add70093362bac3bb664b5fcbe5467c6")
    }

    @Test("signKey 由 accessToken 尾段与 r2/r3 逐字节异或得到")
    func signKeyDerivation() throws {
        let key = try LeapCrypto.deriveSignKey(accessToken: accessToken, r2: r2, r3: r3)
        #expect(key.base64EncodedString() == "/Zm5UXURaIakwrtXcxMz3/2ZuVF1EWiGpMK7V3MTM98=")

        let mac = LeapCrypto.hmacSHA256Hex(
            message: LeapCrypto.sortAndConcatValues(signHeaders, [:]), key: key
        )
        #expect(mac == "8d2e283ad31a6ceb9a86d6f1c64c2cbfa337d8fdd608fe515943cf917e46b4f7")
    }

    @Test("操作密码 AES-128-CBC 加密，key/iv 来自老 token 前后各 32 字符")
    func operationPassword() throws {
        let encrypted = try LeapCrypto.encryptOperationPassword("123456", oldToken: token)
        #expect(encrypted == "sKY77szcUu5zHFrmWMiP8w==")
    }

    @Test("token 太短时拒绝加密，而不是产出错误密文")
    func operationPasswordRejectsShortToken() {
        #expect(throws: LeapError.self) {
            try LeapCrypto.encryptOperationPassword("123456", oldToken: "tooshort")
        }
    }

    @Test("手机号 RSA 加密产出 1024 位密文的 base64url")
    func phoneEncryption() throws {
        let cipher = try LeapCrypto.phoneNoCiphertext("13800138000")
        // PKCS1 填充带随机数，密文每次不同，只能校验结构。
        #expect(LeapCrypto.base64URLDecode(cipher).count == 128)
        #expect(!cipher.contains("="))
        #expect(!cipher.contains("+"))
        #expect(!cipher.contains("/"))
        #expect(try LeapCrypto.phoneNoCiphertext("13800138000") != cipher)
    }

    @Test("JWT exp 转毫秒")
    func jwtExpiry() {
        #expect(LeapCrypto.jwtExpiryMilliseconds(accessToken) == 1_754_252_000_000)
        #expect(LeapCrypto.jwtExpiryMilliseconds("not-a-jwt") == 0)
    }
}

/// 车窗刻度按车型映射，弄反会把"关窗"发成"开窗"。
///
/// 对外统一是开度百分比（0 关闭、100 全开）；S01 车端那套是倒过来的 0…10，
/// 换算错一次，用户点"关闭"车窗会全开着停在路边。
struct WindowCommandTests {

    @Test("S01 下发时换算回倒序的 0…10")
    func s01UsesInvertedScale() {
        // 开度 100 = 全开 = 车端的 0；开度 0 = 关闭 = 车端的 10。
        #expect(LeapCommand.windowValue(openness: 100, carType: "S01") == "0")
        #expect(LeapCommand.windowValue(openness: 20, carType: "S01") == "8")
        #expect(LeapCommand.windowValue(openness: 0, carType: "S01") == "10")
    }

    @Test("S01 越界开度被夹取，不会发出非法值")
    func s01ClampsOutOfRange() {
        #expect(LeapCommand.windowValue(openness: -5, carType: "S01") == "10")
        #expect(LeapCommand.windowValue(openness: 999, carType: "S01") == "0")
    }

    /// 预约类命令走另一个端点，路由判断错了会把指令发到不存在的地址。
    /// state 参数格式还没有验证样本，所以目前没有构造这些命令的入口，只保留路由。
    @Test("只有 161/171/361/392 被当成预约命令")
    func appointmentRouting() {
        for cmdid in ["161", "171", "361", "392"] {
            let command = LeapCommand(cmdid: cmdid, stateJSON: "{}", label: "预约")
            #expect(command.isAppointment)
        }
        for command in [LeapCommand.lock(), .unlock(), .trunk(), .horn(), .quickCool()] {
            #expect(!command.isAppointment)
        }
        // 160/170 是普通远控，不能因为编号相近被误判。
        #expect(!LeapCommand.batteryPreheat(on: true).isAppointment)
    }

    @Test("预约电池预热使用 Android controls 格式")
    func batteryPreheatAppointmentPayload() throws {
        let command = LeapCommand.batteryPreheatAppointment(
            on: true,
            startTime: Date(timeIntervalSince1970: 1_772_000_000),
            vin: "LFZ63AL55RD100000",
            setID: "test-id"
        )
        #expect(command.cmdid == "161")
        let data = try #require(command.stateJSON.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controls = try #require(object["controls"] as? [[String: Any]])
        #expect(controls.first?["on"] as? String == "1")
        #expect(controls.first?["set_id"] as? String == "test-id")
        #expect(controls.first?["days"] as? [Int] == [1, 2, 3, 4, 5])
    }

    /// 不传 `setID` 时自己拼的那个 id。实测格式是「前缀_VIN_创建毫秒」，
    /// 官方用 `Android_`，这里如实标 `iOS_`。尾部毫秒和 `update_time` 必须是同一个数——
    /// 分两次取时间戳的话，跨毫秒边界时两者会差 1，而这种错一年也复现不了几次。
    @Test("预约 set_id 按「iOS_VIN_毫秒」拼，尾部毫秒与 update_time 同源")
    func batteryPreheatAppointmentGeneratedSetID() throws {
        let vin = "LFZ63AL55RD100000"
        let command = LeapCommand.batteryPreheatAppointment(
            on: true,
            startTime: Date(timeIntervalSince1970: 1_772_000_000),
            vin: vin
        )
        let data = try #require(command.stateJSON.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let control = try #require((object["controls"] as? [[String: Any]])?.first)
        let setID = try #require(control["set_id"] as? String)

        let parts = setID.split(separator: "_")
        #expect(parts.count == 3)
        #expect(parts.first == "iOS")
        #expect(parts.dropFirst().first == Substring(vin))
        let tail = try #require(parts.last)
        #expect(Int(tail) != nil)
        // update_time 是字符串口径（和 `on` 一样），别按数字比。
        #expect(control["update_time"] as? String == String(tail))
    }

    @Test("四档人人都有，滑杆只给验证过的车型")
    func windowPresetsFollowCarType() {
        // 四档是统一的开度百分比，各车型下发时再按自己的刻度换算（见 windowValue）。
        // S01 / T03 原先少一个「半开」，那是没来由的：两边中点都是能发的值。
        for type in ["S01", "T03", "C11", "B10", ""] {
            #expect(LeapCommand.windowPresets(carType: type).map(\.openness) == [0, 20, 50, 100])
        }

        // 滑杆只给验过「下发和上报是同一套刻度」的车型，松手后车报回来的位置对得上。
        #expect(LeapCommand.windowSupportsSlider(carType: "S01"))
        // C11 下发 0…10、上报 0…100，滑杆停哪儿车不回音，只给按钮档位。
        #expect(!LeapCommand.windowSupportsSlider(carType: "C11"))
        // T03 2026-08-10 真车验明：下发 `50` 车报回 `51`（差 1 是电机停位精度），
        // 上下行同一把 0…100 的尺子，所以也给滑杆。
        #expect(LeapCommand.windowSupportsSlider(carType: "T03"))
        #expect(!LeapCommand.windowSupportsSlider(carType: "B10"))
        #expect(!LeapCommand.windowSupportsSlider(carType: ""))

        // C11 那组：正序 0…10，半开发 5。
        #expect(LeapCommand.windowValue(openness: 50, carType: "B10") == "5")
    }

    @Test("T03 下发就是 0…100 的百分比，全开发 100 不是 50")
    func t03UsesLinearPercent() {
        // 2026-08-10 真车证伪了原先抄 demo 的 `0/20/50` 三档映射：
        // 车主点「全开」（那时发的是 `50`），**车窗只开了一半**——`50` 就是 50%。
        #expect(LeapCommand.windowValue(openness: 100, carType: "T03") == "100")
        #expect(LeapCommand.windowValue(openness: 50, carType: "T03") == "50")
        #expect(LeapCommand.windowValue(openness: 20, carType: "T03") == "20")
        #expect(LeapCommand.windowValue(openness: 0, carType: "T03") == "0")
        // 越界照样夹取，不发非法值。
        #expect(LeapCommand.windowValue(openness: 999, carType: "T03") == "100")
        #expect(LeapCommand.windowValue(openness: -5, carType: "T03") == "0")
    }

    @Test("尾门能开也能关，判据跟着方向走")
    func trunkOpensAndCloses() {
        // S01 只能远程开，C11 两边都行。关闭发的 false 是照着开启推的，没有文档依据。
        #expect(LeapCommand.trunk().stateJSON.contains("true"))
        #expect(LeapCommand.trunk(open: true).expectation == .trunkOpen(true))
        #expect(LeapCommand.trunk(open: false).stateJSON.contains("false"))
        #expect(LeapCommand.trunk(open: false).expectation == .trunkOpen(false))
        // 两条都得走操作密码，别因为多了个参数漏掉验证。
        #expect(LeapCommand.trunk(open: false).requiresOperationPassword)
    }

    @Test("遮阳帘/天窗/前备箱：cmdid 和值域各归各，别串台")
    func bodyControlCommands() {
        // 三条的 value 刻度互不相同（10 / 1 / 100），全是反编译钉死的，改齐了反而是错的。
        let sunshade = LeapCommand.sunshade(open: true)
        #expect(sunshade.cmdid == "240")
        #expect(sunshade.stateJSON == #"{"value":"10"}"#)
        #expect(LeapCommand.sunshade(open: false).stateJSON == #"{"value":"0"}"#)
        // 任何口径的车况都没有遮阳帘/天窗字段，确认必须是 .unobservable——
        // 挂了判据会白等 20 秒然后误报「未收到车辆确认」。
        #expect(sunshade.expectation == .unobservable)

        let sunroof = LeapCommand.sunroof(open: true)
        #expect(sunroof.cmdid == "300")
        #expect(sunroof.stateJSON == #"{"value":"1"}"#)
        #expect(LeapCommand.sunroof(open: false).stateJSON == #"{"value":"0"}"#)
        #expect(sunroof.expectation == .unobservable)

        // 前备箱有车况位（1282），判据跟着方向走，和尾门同款。
        let frunk = LeapCommand.frunk(open: true)
        #expect(frunk.cmdid == "131")
        #expect(frunk.stateJSON == #"{"value":"100"}"#)
        #expect(frunk.expectation == .frontTrunkOpen(true))
        #expect(LeapCommand.frunk(open: false).expectation == .frontTrunkOpen(false))

        // 三条都是车身控制，操作密码一个都不能少。
        for command in [sunshade, sunroof, frunk] {
            #expect(command.requiresOperationPassword)
        }
    }

    @Test("C11 下发的是 0…10，上报的是 0…100，差十倍")
    func c11SendsTenthScale() {
        // 上报是百分比，我一度据此把下发也改成发百分比，真车上直接不动了：
        // 发 20、50 服务端回 code=0 车没反应（超出 0…10 被丢掉）。
        // 回退到老版的 5 车动了，但只开一半——所以 5 是半开，全开得发 10。
        #expect(LeapCommand.windowValue(openness: 0, carType: "C11") == "0")
        #expect(LeapCommand.windowValue(openness: 20, carType: "C11") == "2")
        #expect(LeapCommand.windowValue(openness: 50, carType: "C11") == "5")
        #expect(LeapCommand.windowValue(openness: 100, carType: "C11") == "10")
    }
}

/// 车况字段的语义以 SDK 的 fieldDefinitions 为准，不能按字段名臆测。
struct VehicleStateTests {

    private func state(_ pairs: [String: String]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        return state
    }

    @Test("driverDoorLockStatus true 表示已锁")
    func lockStatus() {
        #expect(state(["driverDoorLockStatus": "true"]).isLocked == true)
        #expect(state(["driverDoorLockStatus": "false"]).isLocked == false)
        #expect(state([:]).isLocked == nil)
    }

    @Test("chargeState 1 才是充电中")
    func chargingState() {
        #expect(state(["chargeState": "1"]).isCharging)
        #expect(!state(["chargeState": "0"]).isCharging)
        #expect(!state(["chargeState": "2"]).isCharging)
    }

    @Test("acSetting 为 -1 表示无有效值，有效值夹到 18…32")
    func climateSetting() {
        #expect(state(["acSetting": "-1"]).acSetting == nil)
        #expect(state(["acSetting": "16"]).acSetting == 18)
        #expect(state(["acSetting": "40"]).acSetting == 32)
        #expect(state(["acSetting": "24"]).acSetting == 24)
    }

    /// 真车实测：正在制冷时上报 1。demo 项目的注释把 hot/cold 写反了，不要照抄回去。
    @Test("acCoolingAndHeating 映射：1=制冷、2=制热")
    func climateMode() {
        #expect(ClimateMode.fromRaw(1) == .cold)
        #expect(ClimateMode.fromRaw(2) == .hot)
        // 名字本身就说明了：nohotcold 既不制冷也不制热，就是通风；hotcold 冷热都可能，是自动。
        // C11 上实测下发 nohotcold 得到的正是通风，两边对得上。
        #expect(ClimateMode.fromRaw(0) == .vent)
        #expect(ClimateMode.fromRaw(3) == .auto)
    }

    @Test("车端没上报模式时返回 nil，不当成「自动」")
    func climateModeAbsentIsNotAuto() {
        // C11 不上报这个字段。原来 nil 会落进 default 变成 .auto，
        // 十秒一次的轮询就把用户刚选的「制冷」反复冲成「自动」。
        #expect(ClimateMode.fromRaw(nil) == nil)
        #expect(ClimateMode.fromRaw(99) == nil)
    }

    @Test("下发的 mode 字符串与 demo 命令预设一致")
    func climateWireValues() {
        #expect(ClimateMode.cold.wireValue == "cold")
        #expect(ClimateMode.hot.wireValue == "hot")
        // 真车实测下发 nohotcold 之后车上是通风：模式原始值 4、自动位仍是 0、
        // 电流从 1.0 掉到 0.5（只剩鼓风机）。车主对照车机确认就是通风。
        #expect(ClimateMode.vent.wireValue == "nohotcold")
        #expect(ClimateMode.auto.wireValue == "hotcold")
    }

    /// 自动不在 mode 那一层：hotcold 发过去车况纹丝不动，服务端还回 code=0。
    @Test("选自动时 operate 发 auto，其余发 manual")
    func climateAutoUsesOperate() {
        func operateValue(_ mode: ClimateMode) -> String? {
            let command = LeapCommand.climate(
                on: true, temperature: 24, fanLevel: 3, mode: mode, circleIn: true, windshield: false
            )
            let data = Data(command.stateJSON.utf8)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            return json?["operate"]
        }
        #expect(operateValue(.auto) == "auto")
        #expect(operateValue(.cold) == "manual")
        #expect(operateValue(.vent) == "manual")
    }

    @Test("车窗远控能力值只有原始值 2 代表支持")
    func windowRemoteSupport() {
        // 支持位报 2 是必要不充分：两台 T03 实测都报 2，只有报了车窗开度的那台真能控。
        // 完整判据和依据见 `SignalSchemaTests.windowRemoteSupportNeedsOpennessFields`。
        #expect(state([
            "isSupportWindowsRemoteControl": "2", "leftFrontWindowPercent": "0"
        ]).windowsRemoteSupported)
        #expect(!state(["isSupportWindowsRemoteControl": "2"]).windowsRemoteSupported)
        #expect(!state(["isSupportWindowsRemoteControl": "1"]).windowsRemoteSupported)
        // 整个不报支持位 = 数字口径那套，官方无条件放行。
        #expect(state([:]).windowsRemoteSupported)
    }

    @Test("胎压状态字符串 1 表示告警")
    func tireWarning() {
        #expect(state(["leftFrontTirePressure": "252", "leftFrontTirePressureState": "1"]).hasTireWarning)
        #expect(!state(["leftFrontTirePressure": "252", "leftFrontTirePressureState": "0"]).hasTireWarning)
    }
}

/// 桌面卡片上只有一行字的位置，选错了内容用户就看不到该看的。
struct VehicleSnapshotTests {

    private func snapshot(_ mutate: (inout VehicleSnapshot) -> Void) -> VehicleSnapshot {
        var value = VehicleSnapshot.placeholder
        mutate(&value)
        return value
    }

    @Test("异常状态优先于常规信息展示")
    func headlinePrioritisesProblems() {
        #expect(snapshot { $0.anyDoorOpen = true }.headline == "有车门未关闭")
        #expect(snapshot { $0.trunkOpen = true }.headline == "尾门未关闭")
        #expect(snapshot { $0.hasTireWarning = true }.headline == "胎压异常")
        #expect(snapshot { $0.windowsClosed = false }.headline == "车窗未关闭")
        // 车门比胎压更急，同时出现时先报车门。
        #expect(snapshot {
            $0.anyDoorOpen = true
            $0.hasTireWarning = true
        }.headline == "有车门未关闭")
    }

    @Test("没有异常时依次展示充电、空调、位置")
    func headlineFallsBackToStatus() {
        #expect(snapshot { $0.isCharging = true }.headline == "充电中 · 上限 90%")
        #expect(snapshot {
            $0.isCharging = true
            $0.chargeLimit = nil
        }.headline == "充电中")
        #expect(snapshot { $0.climateOn = true }.headline == "空调运行中")
        #expect(snapshot { $0.locationName = "杭州市滨江区" }.headline == "杭州市滨江区")
        #expect(snapshot { $0.locationName = nil }.headline == "已锁车")
    }

    @Test("需要提醒的状态被正确识别")
    func attentionFlags() {
        #expect(!VehicleSnapshot.placeholder.needsAttention)
        #expect(snapshot { $0.isLocked = false }.needsAttention)
        #expect(snapshot { $0.anyDoorOpen = true }.needsAttention)
        #expect(snapshot { $0.trunkOpen = true }.needsAttention)
        #expect(snapshot { $0.hasTireWarning = true }.needsAttention)
        #expect(snapshot { $0.windowsClosed = false }.needsAttention)
        // 读不到尾门状态不等于尾门开着，不能凭空报警。
        #expect(!snapshot { $0.trunkOpen = nil }.needsAttention)
    }

    /// 这一项漏过一次：`anyDoorOpen` 只看四个车门，尾门必须单独带过来，
    /// 否则卡片上那颗键永远是灰的——App 内快控条亮着，卡片却一点反应没有。
    @Test("尾门状态要从车况带进快照")
    func carriesTrunkState() {
        func state(_ pairs: [String: String]) -> VehicleState {
            var value = VehicleState()
            value.signalMap = pairs
            return value
        }
        func made(_ pairs: [String: String]) -> VehicleSnapshot {
            VehicleSnapshot.make(state: state(pairs), vehicleName: "S01", locationName: nil)
        }
        #expect(made(["bbcmBackDoorStatus": "true"]).trunkOpen == true)
        #expect(made(["bbcmBackDoorStatus": "false"]).trunkOpen == false)
        #expect(made([:]).trunkOpen == nil)
        // 尾门开着不该被算进「有车门未关闭」，那是四个车门的事。
        #expect(!made(["bbcmBackDoorStatus": "true"]).anyDoorOpen)
    }

    @Test("老快照没有尾门这个键，解出来是 nil 而不是失败")
    func decodesSnapshotWithoutTrunkKey() throws {
        var data = try JSONEncoder().encode(VehicleSnapshot.placeholder)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "trunkOpen")
        data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VehicleSnapshot.self, from: data)
        #expect(decoded.trunkOpen == nil)
        #expect(!decoded.needsAttention)
    }

    /// 写错 SF Symbol 的名字，**编译器不拦、运行时不报错，那个位置直接画成空白**。
    /// `lock.badge.questionmark` 就是这么混进去的——凭印象写的，SF Symbols 里没这个东西，
    /// 直到锁屏圆钮要靠图标形状区分状态时才发现。锁状态那三个字形尤其不能错：
    /// 锁屏那一片是单色渲染的，颜色传达不了信息，形状是唯一的信息载体。
    @Test("锁状态的三个图标都得是真实存在的 SF Symbol")
    func lockSymbolsExist() {
        for locked in [true, false, nil] as [Bool?] {
            let symbol = snapshot { $0.isLocked = locked }.lockSymbol
            #expect(UIImage(systemName: symbol) != nil, "SF Symbol 不存在：\(symbol)")
        }
    }

    @Test("超过半小时的数据标记为过期，措辞不说「2秒钟前」")
    func freshness() {
        #expect(!VehicleSnapshot.placeholder.isStale)
        #expect(snapshot { $0.reportedAt = .now.addingTimeInterval(-3600) }.isStale)
        #expect(snapshot { $0.reportedAt = .now.addingTimeInterval(-2) }.freshnessText == "刚刚更新")
        #expect(snapshot { $0.reportedAt = .now.addingTimeInterval(-300) }.freshnessText == "更新于 5 分钟前")
        #expect(snapshot { $0.reportedAt = .now.addingTimeInterval(-7200) }.freshnessText == "更新于 2 小时前")
    }

    /// 锁屏控件是个开关，系统把"拨过去之后的值"当目标态发下去，所以**显示什么就决定了
    /// 按下去发哪个方向**：显示「已锁车」时按一下发的是解锁。快照几十分钟没人刷的时候，
    /// 那一按就是把车打开——车主实测过，解锁后开了几十分钟，下车按锁，车没锁上。
    ///
    /// 所以过期的锁状态必须降级成 nil：控件那边 `showsLocked` 随之变 false，
    /// 方向落到锁车这边，最差也就是多锁一次。
    @Test("过期的锁状态不能拿来决定按下去发哪个方向")
    func trustedLockDropsStaleState() {
        // 新鲜的照原样给出，两个方向都要
        #expect(snapshot { $0.isLocked = true; $0.reportedAt = .now }.trustedLock == true)
        #expect(snapshot { $0.isLocked = false; $0.reportedAt = .now }.trustedLock == false)

        // 过期的一律 nil——尤其是「已锁车」那一份，它才是会让人按出反方向的那个
        let stale = snapshot { $0.isLocked = true; $0.reportedAt = .now.addingTimeInterval(-2700) }
        #expect(stale.isLocked == true, "原始值不该被改动，卡片还要照它显示")
        #expect(stale.trustedLock == nil)
        #expect(snapshot { $0.isLocked = false; $0.reportedAt = .now.addingTimeInterval(-2700) }.trustedLock == nil)

        // 车端压根没报的，新鲜与否都还是 nil
        #expect(snapshot { $0.isLocked = nil; $0.reportedAt = .now }.trustedLock == nil)
    }

    /// 阈值必须和 `isStale` 是同一个，不许在控件那边另设一套——
    /// 判据分叉过一次，同一台车两个表面给出过两个说法。
    @Test("可信锁状态的阈值就是 isStale 那一个")
    func trustedLockSharesStaleThreshold() {
        for seconds in [0.0, 600, 1799, 1801, 3600] {
            let sample = snapshot { $0.isLocked = true; $0.reportedAt = .now.addingTimeInterval(-seconds) }
            #expect((sample.trustedLock == nil) == sample.isStale, "\(seconds) 秒时两者不一致")
        }
    }

    /// 车休眠着不上报时，服务端会把同一份旧数据一直发回来。按本机拉取时间算的话
    /// 卡片上永远写着「刚刚」，而那份车况可能是半小时前的——这正是「刷新不及时」的真身。
    @Test("车端采集时刻优先于本机拉取时刻")
    func freshnessPrefersReportedAt() {
        let sleeping = snapshot {
            $0.updatedAt = .now
            $0.reportedAt = .now.addingTimeInterval(-2700)
        }
        #expect(sleeping.freshnessText == "更新于 45 分钟前")
        #expect(sleeping.isStale)
    }

    /// 车端时刻读不到时退回本机拉取时间，但动词必须改口——那句话只能保证
    /// 「几分钟前问过」，保证不了「车况就是那时候的」。
    @Test("读不到车端时刻就改口说「读取」")
    func freshnessFallsBackToFetchTime() {
        let unknown = snapshot {
            $0.updatedAt = .now.addingTimeInterval(-300)
            $0.reportedAt = nil
        }
        #expect(unknown.freshnessText == "读取于 5 分钟前")
    }

    @Test("快照可往返编解码，卡片进程读到的和写入的一致")
    func codableRoundTrip() throws {
        let original = VehicleSnapshot.placeholder
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleSnapshot.self, from: data)
        #expect(decoded == original)
    }
}

/// 服务端返回结构在各接口之间不一致，深度查找必须稳。
struct JSONValueTests {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("深度查找嵌套在任意层级的 signalMap")
    func findsNestedObject() throws {
        let value = try decode(#"{"code":0,"data":{"items":[{"signalMap":{"soc":"76"}}]}}"#)
        let found = value.firstObject(where: { $0["signalMap"]?.objectValue != nil })
        #expect(found?["signalMap"]?["soc"]?.stringValue == "76")
    }

    @Test("数字与布尔都能取成字符串，整数不带小数点")
    func stringCoercion() throws {
        let value = try decode(#"{"a":76,"b":true,"c":"x","d":1.5}"#)
        #expect(value["a"]?.stringValue == "76")
        #expect(value["b"]?.stringValue == "true")
        #expect(value["c"]?.stringValue == "x")
        #expect(value["d"]?.stringValue == "1.5")
    }

    @Test("code 与 result 两种返回码都识别")
    func responseCodes() throws {
        #expect(try decode(#"{"code":0}"#).isSuccess)
        #expect(try decode(#"{"result":0}"#).isSuccess)
        #expect(try decode(#"{"result":200}"#).isSuccess)
        #expect(try !decode(#"{"result":39,"msg":"信息校验失败"}"#).isSuccess)
        #expect(try decode(#"{"success":true,"code":1}"#).isSuccess)
    }

    @Test("按 vin 收集车辆，去掉重复")
    func collectsVehicles() throws {
        let value = try decode(#"{"data":[{"vin":"LP00000000000001"},{"nested":{"vin":"LP00000000000002"}}]}"#)
        let objects = value.allObjects(where: { ($0["vin"]?.stringValue?.count ?? 0) >= 8 })
        #expect(objects.count == 2)
    }
}

/// 指令的预期终态。
///
/// 这套判定取代了原来"信回执"的做法：回执接口的返回结构没有已验证样本，
/// 而 `JSONValue.isSuccess` 在响应缺少 code/result/status 时会直接判成功，
/// 早期版本因此第一次查询（下发后 2 秒）就退出了等待，车根本还没动。
@Suite("控车确认")
struct ControlExpectationTests {

    private func state(_ pairs: [String: String]) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        return state
    }

    @Test("上锁要等到车况报已锁，中途不算数")
    func lockExpectation() {
        let command = LeapCommand.lock()
        #expect(command.expectation == .locked(true))
        #expect(!command.expectation.isSatisfied(by: state(["driverDoorLockStatus": "false"])))
        #expect(command.expectation.isSatisfied(by: state(["driverDoorLockStatus": "true"])))
        // 字段还没上报时不能当成已生效。
        #expect(!command.expectation.isSatisfied(by: state([:])))
    }

    @Test("解锁的预期终态与上锁相反")
    func unlockExpectation() {
        #expect(LeapCommand.unlock().expectation == .locked(false))
        #expect(LeapCommand.unlock().expectation.isSatisfied(by: state(["driverDoorLockStatus": "false"])))
    }

    @Test("关空调只看开关")
    func climateOffExpectation() {
        let command = LeapCommand.climate(
            on: false, temperature: 24, fanLevel: 3, mode: .cold, circleIn: true, windshield: false
        )
        #expect(command.expectation.isSatisfied(by: state(["acSwitch": "false"])))
        #expect(!command.expectation.isSatisfied(by: state(["acSwitch": "true"])))
    }

    @Test("开空调连温度和风量一起确认，否则改温度会立刻误判成功")
    func climateOnExpectation() {
        let command = LeapCommand.climate(
            on: true, temperature: 22, fanLevel: 5, mode: .cold, circleIn: true, windshield: false
        )
        // 空调本来就开着、但温度还是旧值——不能算成功。
        #expect(!command.expectation.isSatisfied(by: state(["acSwitch": "true", "acSetting": "26"])))
        #expect(command.expectation.isSatisfied(
            by: state(["acSwitch": "true", "acSetting": "22", "acAirVolume": "5"])
        ))
    }

    @Test("车端缺报某一项时不作为否决条件")
    func climateToleratesMissingFields() {
        let command = LeapCommand.climate(
            on: true, temperature: 22, fanLevel: 5, mode: .cold, circleIn: true, windshield: false
        )
        // 只报了开关和温度，风量没报——宁可确认得宽一点，也不要误报"车辆未响应"。
        #expect(command.expectation.isSatisfied(by: state(["acSwitch": "true", "acSetting": "22"])))
    }

    @Test("前备箱要等信号 1282 翻转，缺报不算生效")
    func frunkExpectation() {
        let open = LeapCommand.frunk(open: true)
        // 数字口径：1282 是前备箱开合位（官方 isFrontTrunkLock）。
        var closed = VehicleState()
        closed.signalMap = ["1282": "0"]
        closed.schema = .numeric
        #expect(!open.expectation.isSatisfied(by: closed))

        var opened = closed
        opened.signalMap["1282"] = "1"
        #expect(open.expectation.isSatisfied(by: opened))
        #expect(LeapCommand.frunk(open: false).expectation.isSatisfied(by: closed))

        // 字段还没上报时不能当成已生效（同上锁那条的规矩）。
        var empty = VehicleState()
        empty.schema = .numeric
        #expect(!open.expectation.isSatisfied(by: empty))
    }

    @Test("极速降温的判据是它自己那套温度风量")
    func quickCoolExpectation() {
        let command = LeapCommand.quickCool()
        #expect(command.expectation == .climate(on: true, temperature: 18, fanLevel: 7, mode: .cold))
    }

    /// 只改模式那种指令，温度风量本来就没变，不把模式算进判据就会一发出去立刻判成功。
    @Test("只改模式时，车没换过来就不算成功")
    func climateModeIsPartOfExpectation() {
        let command = LeapCommand.climate(
            on: true, temperature: 26, fanLevel: 1, mode: .auto, circleIn: true, windshield: false
        )
        // C11：3713 的 1 是制冷、0 是自动。温度风量都对上了，但模式还没换。
        var stale = VehicleState()
        stale.signalMap = ["1938": "1", "2183": "26", "1941": "1", "3713": "1"]
        stale.schema = .numeric
        #expect(!command.expectation.isSatisfied(by: stale))

        var applied = stale
        applied.signalMap["3713"] = "0"
        #expect(command.expectation.isSatisfied(by: applied))
    }

    @Test("车不上报模式的车型，判据自动跳过这一项")
    func climateModeSkippedWhenUnreported() {
        let command = LeapCommand.climate(
            on: true, temperature: 26, fanLevel: 1, mode: .auto, circleIn: true, windshield: false
        )
        var state = VehicleState()
        state.signalMap = ["1938": "1", "2183": "26", "1941": "1"]
        state.schema = .numeric
        #expect(command.expectation.isSatisfied(by: state))
    }

    @Test("只有上下行同刻度的车窗能和上报值比对")
    func windowExpectation() {
        #expect(LeapCommand.window(openness: 20, carType: "S01").expectation == .windowPosition(20))
        #expect(LeapCommand.window(openness: 20, carType: "T03").expectation == .windowPosition(20))
        // C11 那套口径下发 0…10、上报 0…100，两边不是一套刻度，
        // 发 `2` 之后车报回来是不是正好 20 没试过，比对会误报未响应。
        #expect(LeapCommand.window(openness: 20, carType: "C11").expectation == .unobservable)
        // 同口径的其他车型一样不比对——这条和滑杆不同，不因为口径通用就放开。
        #expect(LeapCommand.window(openness: 20, carType: "B10").expectation == .unobservable)
    }

    @Test("车窗停位比对留 ±5 容差")
    func windowPositionTolerance() {
        // T03 发 `50` 车报回 `51`，精确相等会把一次成功的控车判成未响应。
        func stateWith(_ percent: String) -> VehicleState {
            var s = VehicleState()
            s.signalMap = ["soc": "80", "leftFrontWindowPercent": percent]
            s.schema = SignalSchema.detect(s.signalMap, carType: "T03")
            return s
        }
        #expect(ControlExpectation.windowPosition(50).isSatisfied(by: stateWith("51")))
        #expect(ControlExpectation.windowPosition(50).isSatisfied(by: stateWith("45")))
        // 超出容差仍然算没确认，不能因为放宽就什么都认。
        #expect(!ControlExpectation.windowPosition(50).isSatisfied(by: stateWith("40")))
        #expect(!ControlExpectation.windowPosition(100).isSatisfied(by: stateWith("51")))
        // 读不到开度就是读不到，不能当成已满足。
        var blank = VehicleState()
        blank.signalMap = ["soc": "80"]
        blank.schema = SignalSchema.detect(blank.signalMap, carType: "T03")
        #expect(!ControlExpectation.windowPosition(50).isSatisfied(by: blank))
    }

    @Test("鸣笛和电池预热没有可观测终态")
    func unobservableCommands() {
        #expect(!LeapCommand.horn().expectation.isObservable)
        #expect(!LeapCommand.batteryPreheat(on: true).expectation.isObservable)
        // 确认不了就永远不该自称已生效。
        #expect(!ControlExpectation.unobservable.isSatisfied(by: state(["acSwitch": "true"])))
    }

    @Test("尾门看后备箱状态")
    func trunkExpectation() {
        let command = LeapCommand.trunk()
        #expect(command.expectation.isSatisfied(by: state(["bbcmBackDoorStatus": "true"])))
        #expect(!command.expectation.isSatisfied(by: state(["bbcmBackDoorStatus": "false"])))
    }
}

/// 卡片和锁屏控件下发之后要回读车况证实，这两个判据决定了那圈轮询怎么退出、
/// 退不出来时又该把什么写回快照。写错任何一个都不会编译报错，只会在实车上
/// 变成"按了没成却显示成了"或者"白等十秒"。
@Suite("回读轮询的退出条件")
struct ControlActivityActionTests {

    private func snapshot(_ mutate: (inout VehicleSnapshot) -> Void) -> VehicleSnapshot {
        var value = VehicleSnapshot.placeholder
        mutate(&value)
        return value
    }

    /// `confirms` 对尾门和鸣笛恒为 false（车端根本不报"刚刚做过没有"），
    /// 拿它当轮询的退出条件就永远退不出来——三轮白等十秒，还多发两次请求。
    @Test("尾门和鸣笛没有可观测终态，不该白等三轮")
    func verifiability() {
        #expect(ControlActivityAction.lock.isVerifiable)
        #expect(ControlActivityAction.unlock.isVerifiable)
        #expect(ControlActivityAction.climateOn.isVerifiable)
        #expect(ControlActivityAction.climateOff.isVerifiable)
        #expect(!ControlActivityAction.trunk.isVerifiable)
        #expect(!ControlActivityAction.horn.isVerifiable)

        // 判据得和 `confirms` 对得上：说不可证实的，`confirms` 就该恒为 false。
        for action in [ControlActivityAction.trunk, .horn] {
            #expect(!action.confirms(.placeholder))
        }
    }

    /// 三轮都没证实时会把 `isLocked` 标成 nil（读不到），好让锁屏控件那一按
    /// 落在锁车方向。这个降级只对动车锁的动作成立——鸣笛完了把锁状态抹掉，
    /// 等于让控件平白无故忘掉一份刚读到的车况。
    @Test("只有动车锁的动作，回读不成时才把锁状态标成读不到")
    func lockActionScope() {
        #expect(ControlActivityAction.lock.isLockAction)
        #expect(ControlActivityAction.unlock.isLockAction)
        for action in [ControlActivityAction.trunk, .horn, .climateOn, .climateOff] {
            #expect(!action.isLockAction)
        }
    }

    /// 开关拨到哪一边决定发哪个方向，这条链路上任何一环反了都是"想锁车，车开了"。
    /// `LockControlIntent.value` 里 true = 解锁，`run` 收的 `desiredLock` 是它的反面。
    /// `isStale` 现在是 `isOlderThan(1800)` 的一层薄壳。两者哪天走岔了，
    /// "半小时才算旧"这句话就会在显示和判方向两处说出不同的答案。
    @Test("isStale 就是半小时那一档 isOlderThan")
    func staleIsOlderThanHalfHour() {
        for seconds in [0, 60, 1799, 1801, 3600] as [TimeInterval] {
            let sample = snapshot { $0.reportedAt = .now.addingTimeInterval(-seconds) }
            #expect(sample.isStale == sample.isOlderThan(1800), "\(seconds) 秒时两者不一致")
        }
    }

    @Test("锁屏开关给的目标态压过快照，不照着快照取反")
    func desiredLockWins() {
        let fresh = VehicleSnapshot.placeholder
        #expect(fresh.isLocked == true)
        // 快照说「已锁车」，但用户在开关上要的是解锁——听用户的
        #expect(ControlActivityAction(.toggleLock, desiredLock: false, snapshot: fresh) == .unlock)
        #expect(ControlActivityAction(.toggleLock, desiredLock: true, snapshot: fresh) == .lock)
        // 桌面卡片给不出目标态，那才照快照算
        #expect(ControlActivityAction(.toggleLock, desiredLock: nil, snapshot: fresh) == .unlock)
    }

    /// 「只管锁车」卡说读不到就锁车，卡片按钮那条却写着 `(isLocked ?? true) ? .unlock : .lock`
    /// ——同一台车、同一个"读不到"，两个表面按出两个相反的方向。统一到一个判据之后
    /// 这条测试就是那份约定：**只有确知车锁着才发解锁，其余一律锁车。**
    @Test("读不到或过期时，按下去一律是锁车")
    func lockActionTargetPrefersLocking() {
        // 确知锁着 → 唯一发解锁的情形
        #expect(!snapshot { $0.isLocked = true; $0.reportedAt = .now }.lockActionTarget)
        // 确知开着 → 锁车
        #expect(snapshot { $0.isLocked = false; $0.reportedAt = .now }.lockActionTarget)
        // 车端没报 → 锁车
        #expect(snapshot { $0.isLocked = nil; $0.reportedAt = .now }.lockActionTarget)
        // 报了「已锁车」但已经过期 → 还是锁车，这条正是车主实测踩到的那个
        #expect(snapshot { $0.isLocked = true; $0.reportedAt = .now.addingTimeInterval(-2700) }.lockActionTarget)
    }

    /// 灵动岛上写的那句话和真正发出去的指令必须同源，否则会出现
    /// 「正在锁车」配一条解锁指令。两边都读 `lockActionTarget` 之后才对得上。
    @Test("灵动岛文案和下发方向同源")
    func activityTextMatchesCommand() {
        let staleLocked = snapshot { $0.isLocked = true; $0.reportedAt = .now.addingTimeInterval(-2700) }
        #expect(ControlActivityAction(.toggleLock, desiredLock: nil, snapshot: staleLocked) == .lock)
        #expect(ControlActivityAction(.toggleLock, desiredLock: nil, snapshot: nil) == .lock)
    }

    /// 按下车锁键时免不免那趟联网，判据只有一条：状态读到过，而且还没旧过窗口。
    /// 这是车主定的规矩——"10 分钟前刷新过、已知就不用（再拉）"。
    @Test("够新且状态明确才免掉那趟联网")
    func lockTargetShortcut() {
        let window = WidgetControlRunner.lockTargetTrustWindow
        // 刚读到的明确状态 → 直接用，不联网
        #expect(snapshot { $0.isLocked = true; $0.reportedAt = .now }.canDecideLockTarget(within: window))
        #expect(snapshot { $0.isLocked = false; $0.reportedAt = .now }.canDecideLockTarget(within: window))
        // 车端压根没报锁状态 → 必须联网，多新都不算数
        #expect(!snapshot { $0.isLocked = nil; $0.reportedAt = .now }.canDecideLockTarget(within: window))
        // 状态明确但旧过窗口 → 必须联网。车主那次事故就发生在这个区间里
        #expect(!snapshot {
            $0.isLocked = true
            $0.reportedAt = .now.addingTimeInterval(-window - 60)
        }.canDecideLockTarget(within: window))
    }

    /// 窗口取的是卡片刷新间隔那个数。两者对齐，常态下按下去才是立刻走的；
    /// 谁单独改了一边，要么白等网络，要么信一份卡片早就该刷新掉的旧快照。
    @Test("免联网的窗口和卡片刷新间隔同一个数")
    func trustWindowMatchesRefreshInterval() {
        #expect(WidgetControlRunner.lockTargetTrustWindow == 600)
    }
}
