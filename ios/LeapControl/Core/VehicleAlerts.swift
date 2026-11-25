import Foundation

/// 会弹通知的三件事。
enum VehicleAlert: String, Codable, Hashable, Sendable {
    /// 车停着、没锁、超过设定时长。
    case unlocked
    /// 开始充电。
    case chargeStarted
    /// 充电结束。
    case chargeFinished
}

/// 喂给判定引擎的一帧。
///
/// 只放判定真正用得上的字段：多一个字段就多一处要在不同车型上维持正确的东西。
/// 没有车速信号（我们这套协议里拿不到），所以「停着」只能用挡位来近似。
struct VehicleAlertSample {
    var at: Date
    var isLocked: Bool?
    var isDriving: Bool
    var isCharging: Bool
    var chargeState: Int?
    var gunConnected: Bool?
    var powerKW: Double?
    var soc: Int?
}

/// 一条该发的通知。
struct VehicleAlertEvent: Equatable {
    var kind: VehicleAlert
    var at: Date
    var soc: Int?
    var powerKW: Double?
    /// 未锁车持续了多少分钟（只有 `.unlocked` 有）。
    var minutes: Int?
    /// 这一次充进去了几个百分点（只有 `.chargeFinished` 有）。
    var socGain: Int?
}

/// 推送判定。**纯逻辑**：不碰通知中心、不碰网络、不碰 UserDefaults，所以能一条条摆出来测。
///
/// 三条规则：
/// - **未锁车**：车没在开 + 锁状态明确是「未锁」，持续到设定时长才提醒，**只提醒一次**；
///   一旦锁上就复位，下次再解锁才会重新计时。读不到锁状态（`nil`）不提醒——那可能是信号没上报，
///   提醒了也没法确认，叫「狼来了」。
/// - **开始充电**：连续两帧确认在充电才算，挡掉功率在阈值上下抖动造成的假开始。
/// - **充电完成**：从「在充」变成「不在充」，且**车说充完了**（`1149 == 2`）或者**枪还插着**。
///   拔枪上车走人那种不提醒——那是车主自己的动作，不需要手机再告诉他一遍。
struct VehicleAlertEngine {
    struct Settings: Equatable {
        /// 未锁车多久后提醒。
        var unlockedGrace: TimeInterval = 10 * 60
        /// 连续几帧在充电才算真的开始了。
        var chargeStartConfirmations = 2
    }

    var settings = Settings()

    private var unlockedSince: Date?
    private var unlockedAlerted = false
    private var chargingConfirmations = 0
    private var wasCharging = false
    private var chargeStartSoc: Int?
    /// 第一帧只用来对齐状态，不产生充电事件。
    ///
    /// 没有这一步，**冷启动时车正在充电**就会立刻弹一条「开始充电」——而它可能已经充了两小时。
    /// 对齐之后，只有「从不在充变成在充」才算开始。
    private var hasPrimed = false

    /// 上一次充电开始时的电量，给「充了多少」用。
    private(set) var lastChargeStartSoc: Int?

    mutating func ingest(_ sample: VehicleAlertSample) -> [VehicleAlertEvent] {
        var events: [VehicleAlertEvent] = []

        // MARK: 未锁车

        if sample.isLocked == false, !sample.isDriving {
            if unlockedSince == nil { unlockedSince = sample.at }
            if !unlockedAlerted, let since = unlockedSince,
               sample.at.timeIntervalSince(since) >= settings.unlockedGrace {
                unlockedAlerted = true
                events.append(VehicleAlertEvent(
                    kind: .unlocked,
                    at: sample.at,
                    soc: sample.soc,
                    powerKW: nil,
                    minutes: max(1, Int(sample.at.timeIntervalSince(since) / 60)),
                    socGain: nil
                ))
            }
        } else {
            // 锁上了、开始开了、或者读不到锁状态：都算这一段结束。
            unlockedSince = nil
            unlockedAlerted = false
        }

        // MARK: 充电

        let charging = isCharging(sample)
        if !hasPrimed {
            hasPrimed = true
            wasCharging = charging
            chargingConfirmations = 0
            // 冷启动时已经在充：不知道这一趟是从多少开始的，就不给「本次 +X%」。
            chargeStartSoc = nil
        } else if charging {
            chargingConfirmations += 1
            if chargingConfirmations == settings.chargeStartConfirmations, !wasCharging {
                wasCharging = true
                chargeStartSoc = sample.soc
                lastChargeStartSoc = sample.soc
                events.append(VehicleAlertEvent(
                    kind: .chargeStarted,
                    at: sample.at,
                    soc: sample.soc,
                    powerKW: sample.powerKW,
                    minutes: nil,
                    socGain: nil
                ))
            }
        } else {
            chargingConfirmations = 0
            if wasCharging {
                wasCharging = false
                // 车说充完了，或者枪还插着：这是「充满了」。拔枪走人不算。
                if sample.chargeState == 2 || sample.gunConnected != false {
                    let gain: Int? = {
                        guard let end = sample.soc, let start = chargeStartSoc, end > start else { return nil }
                        return end - start
                    }()
                    events.append(VehicleAlertEvent(
                        kind: .chargeFinished,
                        at: sample.at,
                        soc: sample.soc,
                        powerKW: nil,
                        minutes: nil,
                        socGain: gain
                    ))
                }
            }
            chargeStartSoc = nil
        }

        return events
    }

    /// 这一帧算不算在充电。
    ///
    /// 三个来源取或：车报「充电中」（`1149 == 1`）、充电功率够大、或者上层已经判定在充。
    /// 只看 `1149` 不行——有的车型充电时会短暂报别的值；只看功率也不行——降功率涓流时
    /// 会掉到阈值以下，那会把一次充电拆成「开始/完成」两三轮。
    private func isCharging(_ sample: VehicleAlertSample) -> Bool {
        if sample.chargeState == 1 { return true }
        if let power = sample.powerKW, power >= 0.5 { return true }
        return sample.isCharging
    }
}
