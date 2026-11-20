import Foundation

/// 引导车主操作车辆，用车况前后的差异反推信号 ID。
///
/// 存在的理由：零跑没有公开信号表。连续量还能靠量级推——电量落在 0–100、里程是万级、
/// 胎压和 S01 实测的 249–261 同量级。但门窗锁这类布尔量，车停着的时候上报的全是 0，
/// 除了「动一下看谁变了」没有别的办法。
struct CalibrationTask: Identifiable, Sendable {
    let id: String
    /// 这一步要标定的信号。
    let signal: VehicleSignal
    let title: String
    /// 正向动作。
    let forward: String
    /// 复原动作。单向变化可能只是赶巧，反向也跟着变才算数。
    let backward: String
    let hint: String

    /// 八个任务，每个都是「操作 → 复原」两步。
    ///
    /// 顺序有讲究：一次只动一个东西。开车门会顺带解锁，所以车锁排在车门前面先标定完；
    /// 空调的温度和风量得在空调开着的时候调，所以排在开关空调那步后面。
    static let all: [CalibrationTask] = [
        CalibrationTask(
            id: "lock",
            signal: .driverDoorLocked,
            title: "车锁",
            forward: "解锁车辆",
            backward: "重新锁上车辆",
            hint: "用车钥匙或手机钥匙都行，不要开车门"
        ),
        CalibrationTask(
            id: "driverDoor",
            signal: .driverDoor,
            title: "驾驶位车门",
            forward: "打开驾驶位车门",
            backward: "关上驾驶位车门",
            hint: "只开这一扇，其他门保持关闭"
        ),
        CalibrationTask(
            id: "trunk",
            signal: .trunkOpen,
            title: "后备箱",
            forward: "打开后备箱",
            backward: "关上后备箱",
            hint: ""
        ),
        CalibrationTask(
            id: "window",
            signal: .leftFrontWindow,
            title: "主驾车窗",
            forward: "把主驾车窗降下一半",
            backward: "把主驾车窗升回去关好",
            hint: "只动主驾这一扇"
        ),
        CalibrationTask(
            id: "rearWindow",
            signal: .leftRearWindow,
            title: "左后车窗",
            forward: "把左后车窗降下一半",
            backward: "把左后车窗升回去关好",
            hint: "前窗保持关好，只动左后这一扇"
        ),
        CalibrationTask(
            id: "climate",
            signal: .acSwitch,
            title: "空调",
            forward: "打开空调",
            backward: "关闭空调",
            hint: "在车里操作，不要用 App 的空调按钮"
        ),
        CalibrationTask(
            id: "acTemp",
            signal: .acSetting,
            title: "空调温度",
            forward: "先把空调打开，再把设定温度调高 3 度",
            backward: "把温度调回原来的度数",
            hint: "记住原来是多少度，第 2 步要调回同一个值"
        ),
        CalibrationTask(
            id: "acFan",
            signal: .acFanLevel,
            title: "空调风量",
            forward: "把风量调到最大档",
            backward: "把风量调回原来的档位",
            hint: "空调要一直开着；调完风量记得把空调关掉"
        )
    ]
}

/// 一个字段在操作前后的变化。
struct SignalChange: Equatable, Sendable, Codable {
    let key: String
    let before: String
    let after: String
}

/// 一个任务两步走完的结果。
struct TaskOutcome: Equatable, Sendable, Codable {
    let taskID: String
    let signal: String
    let forward: [SignalChange]
    let backward: [SignalChange]
    /// 复原那一步做没做。跳过了就只剩正向证据，判据要换一套更严的。
    var didReverse: Bool = true

    /// 正反两次都变、且值完全对调的 key。只有这种才写进映射表。
    ///
    /// 只在一个方向出现的，可能是车自己在动（空调余温、电压波动），不能算。
    var confirmedKeys: [String] {
        guard didReverse else {
            // 单向任务：唯一站得住的判据是「没有别的字段陪着一起动」。
            // 变了两个就分不清哪个才是目标，整步作废——猜错会把错的 key 写进映射表，
            // 那比这一项认不出来糟得多。
            return forward.count == 1 ? forward.map(\.key) : []
        }
        return forward.compactMap { change in
            guard let back = backward.first(where: { $0.key == change.key }) else { return nil }
            guard back.before == change.after, back.after == change.before else { return nil }
            return change.key
        }.sorted()
    }

    /// 只在一个方向出现的 key，报告里列出来供人工判断，但不生效。
    var unconfirmedKeys: [String] {
        let confirmed = Set(confirmedKeys)
        let all = Set(forward.map(\.key)).union(backward.map(\.key))
        return all.subtracting(confirmed).sorted()
    }

    var isConfirmed: Bool { !confirmedKeys.isEmpty }
}

/// 静止基线：什么都不操作时自己就会变的字段。
///
/// 不先摸清这些，每个任务的 diff 都会混进十几个无关 ID——时间戳每次都变，
/// 经纬度车停着也会飘几十米，电压电流温度是连续量一直在小幅跳。
struct CalibrationBaseline: Equatable, Sendable, Codable {
    var noisyKeys: Set<String> = []
    var sampleCount: Int = 0

    /// 采了好几次却一个字段都没变——车多半睡着了，车端在重复上报同一份缓存。
    ///
    /// 这种基线等于没采：后面每一步的 diff 都会混进时间戳、电压、温度这些一直在跳的字段，
    /// 一次真实的标定就栽在这上面，报告里十几个无关 ID 淹掉了真正的那一个。
    var looksAsleep: Bool { sampleCount > 1 && noisyKeys.isEmpty }

    /// 连续几次静止采样两两相比，变过的都算噪声。
    static func make(from samples: [[String: String]]) -> CalibrationBaseline {
        guard samples.count > 1 else { return CalibrationBaseline(sampleCount: samples.count) }
        var noisy: Set<String> = []
        for (previous, current) in zip(samples, samples.dropFirst()) {
            noisy.formUnion(Calibration.changes(from: previous, to: current).map(\.key))
        }
        return CalibrationBaseline(noisyKeys: noisy, sampleCount: samples.count)
    }
}

enum Calibration {
    /// 两份 signalMap 的差异。只看变化，新增和消失的字段都算。
    static func changes(
        from before: [String: String],
        to after: [String: String],
        excluding noisy: Set<String> = []
    ) -> [SignalChange] {
        var out: [SignalChange] = []
        for key in Set(before.keys).union(after.keys).sorted() where !noisy.contains(key) {
            let old = before[key] ?? ""
            let new = after[key] ?? ""
            guard old != new, !isLocation(key: key, values: [old, new]) else { continue }
            out.append(SignalChange(key: key, before: old, after: new))
        }
        return out
    }

    /// 位置字段无条件排除，不进 diff 也就进不了报告。
    ///
    /// 原来只靠静止基线挡：车停着经纬度也会飘几十米，采样时自然会被划进噪声。
    /// 但有一次车是睡着的，三次采样一模一样，噪声名单空了——坐标跟着每一步 diff 一路进了报告。
    /// 「报告里不含位置」是给车主的承诺，不能建立在「基线刚好采到了」上面。
    static func isLocation(key: String, values: [String]) -> Bool {
        if locationKeys.contains(key) { return true }
        return values.contains(where: looksLikeCoordinate)
    }

    /// 各套体系里所有经纬度的候选 key。
    private static let locationKeys: Set<String> = {
        let schemas = [SignalSchema.legacy, .numeric]
        return Set(schemas.flatMap { schema in
            [VehicleSignal.latitude, .longitude, .privacyGPS].flatMap { schema.candidates(for: $0) }
        })
    }()

    /// 按值的形状兜底：小数点后 4 位以上、落在经纬度量程内。
    ///
    /// 表里没收录的坐标字段也得挡住——C11 至少还有 `2190/2191`、`3724/3725` 两组，
    /// 其中一个就从上一版报告里溜出去了。车上其它连续量（温度 31.5、电压 718.6）
    /// 都只报一位小数，六位小数基本只有坐标。
    private static func looksLikeCoordinate(_ value: String) -> Bool {
        let parts = value.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[1].count >= 4,
              parts[1].allSatisfy(\.isNumber),
              let number = Double(value), abs(number) <= 180
        else { return false }
        return true
    }

    /// 从确认过的任务里取出映射。一个任务只认一个 key——
    /// 同时变了好几个的说明这一步没隔离干净，宁可放弃也不猜哪个才对。
    static func learnedKeys(from outcomes: [TaskOutcome]) -> [VehicleSignal: String] {
        var out: [VehicleSignal: String] = [:]
        for outcome in outcomes {
            guard outcome.confirmedKeys.count == 1,
                  let key = outcome.confirmedKeys.first,
                  let signal = VehicleSignal(rawValue: outcome.signal) else { continue }
            out[signal] = key
        }
        return out
    }

    /// 导出给开发者的报告。不含 VIN、不含账号，经纬度在 `changes` 里就已经被无条件滤掉。
    static func report(
        carType: String,
        schemaID: String,
        baseline: CalibrationBaseline,
        outcomes: [TaskOutcome],
        at date: Date = .now
    ) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        var lines = [
            "壹跑 车型标定报告",
            "车型: \(carType.isEmpty ? "(未知)" : carType)",
            "字段体系: \(schemaID)",
            "日期: \(stamp)",
            "",
            "【噪声字段】静止时自己会变，已从所有 diff 中排除",
            baseline.noisyKeys.sorted().joined(separator: ", ").ifEmpty("(无)"),
            ""
        ]

        if baseline.looksAsleep {
            lines.append("⚠ 基线一个字段都没变，车很可能是睡着的。")
            lines.append("  下面每一步的 diff 里都会混进时间戳、电压这类自己会跳的字段，")
            lines.append("  双向对调的判据还站得住，单向那几步基本不可信。建议车醒着时重做一次。")
            lines.append("")
        }

        for task in CalibrationTask.all {
            guard let outcome = outcomes.first(where: { $0.taskID == task.id }) else {
                lines.append("【\(task.title)】未做")
                lines.append("")
                continue
            }
            let verdict: String
            if !outcome.isConfirmed {
                verdict = "未确认 ⚠"
            } else {
                verdict = outcome.didReverse ? "双向确认 ✓" : "单向唯一变化 ✓"
            }
            lines.append("【\(task.title)】\(verdict)")
            lines.append("  目标信号: \(task.signal.rawValue)")
            lines.append("  \(task.forward):")
            lines.append(contentsOf: describe(outcome.forward))
            if outcome.didReverse {
                lines.append("  \(task.backward):")
                lines.append(contentsOf: describe(outcome.backward))
            } else {
                lines.append("  \(task.backward): (跳过)")
            }
            if !outcome.confirmedKeys.isEmpty {
                lines.append("  → 确认: \(outcome.confirmedKeys.joined(separator: ", "))")
            }
            if !outcome.unconfirmedKeys.isEmpty {
                lines.append("  → 只单向变化，未采信: \(outcome.unconfirmedKeys.joined(separator: ", "))")
            }
            lines.append("")
        }

        let learned = learnedKeys(from: outcomes)
        lines.append("【可写入映射表】")
        if learned.isEmpty {
            lines.append("(无)")
        } else {
            for (signal, key) in learned.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("  .\(signal.rawValue): \"\(key)\",")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ changes: [SignalChange]) -> [String] {
        guard !changes.isEmpty else { return ["    (没捕捉到变化)"] }
        return changes.map { "    \($0.key): \($0.before.ifEmpty("(无)")) → \($0.after.ifEmpty("(无)"))" }
    }
}

/// 本机标定学到的映射，按车型存在 App Group 里——桌面卡片也要用同一份。
enum LearnedSignals {
    private static let key = "calibration.learned"

    private static func load() -> [String: [String: String]] {
        guard let data = SharedSettings.defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }

    static func keys(for carType: String) -> [VehicleSignal: String] {
        guard !carType.isEmpty, let stored = load()[carType.uppercased()] else { return [:] }
        return stored.reduce(into: [:]) { out, pair in
            guard let signal = VehicleSignal(rawValue: pair.key) else { return }
            out[signal] = pair.value
        }
    }

    static func save(_ learned: [VehicleSignal: String], for carType: String) {
        guard !carType.isEmpty, !learned.isEmpty else { return }
        var all = load()
        // 与已有的合并：分几次标定完也能累加，不会把上次的成果冲掉。
        var stored = all[carType.uppercased()] ?? [:]
        for (signal, key) in learned { stored[signal.rawValue] = key }
        all[carType.uppercased()] = stored
        guard let data = try? JSONEncoder().encode(all) else { return }
        SharedSettings.defaults?.set(data, forKey: key)
    }

    static func clear(for carType: String) {
        var all = load()
        all[carType.uppercased()] = nil
        guard let data = try? JSONEncoder().encode(all) else { return }
        SharedSettings.defaults?.set(data, forKey: key)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
