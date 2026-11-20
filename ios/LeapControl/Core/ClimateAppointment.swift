import Foundation

/// 预约类指令（cmdid 161 预约电池预热、171 预约空调）共用的星期编码。
///
/// **0 = 周日、1 = 周一 … 6 = 周六。** 2026-11-19 按 leapauto 的协议文档定下，171 和 161 一起改。
/// 在此之前我们 161 发的是 1…7（周日 = 7，出自静态分析），两边都没有勾周日的实车样本，
/// 车主拍板按 0 走。如果哪天读回来的预约里出现 `7`，就说明这条定错了。
enum AppointmentWeekday {
    /// 界面上的排列顺序：周一在前、周日在末，和国内日历习惯一致；值仍是协议编码。
    static let ordered: [(value: Int, label: String)] = [
        (1, "一"), (2, "二"), (3, "三"), (4, "四"), (5, "五"), (6, "六"), (0, "日")
    ]

    static let workdays: Set<Int> = [1, 2, 3, 4, 5]

    /// 「每周一、三、五」这种人话。空集合是一次性预约。
    static func summary(_ days: Set<Int>) -> String {
        if days.isEmpty { return "仅一次" }
        if days.count == 7 { return "每天" }
        if days == workdays { return "工作日" }
        if days == [6, 0] { return "周末" }
        let labels = ordered.filter { days.contains($0.value) }.map(\.label)
        return "每周" + labels.joined(separator: "、")
    }
}

/// 一条预约空调（cmdid 171）。
///
/// 协议出处：leapauto 的官方抓包 `[681]`（设置）、`cancel/[332]`（取消）、`[334]`（取消后回读）。
/// 设置 payload 里除了时间、星期、温度、模式之外，风量 / 循环 / 除雾 / 出风位置都是固定值——
/// 车主选的方案是照官方抓包的默认值发（7 档 / 内循环 / 前挡除雾开 / 全车出风），不在界面上暴露。
struct ClimateAppointment: Equatable, Sendable {
    /// 预约只开放制冷 / 制热两档：自动模式在 171 上没有任何样本（空调立即控制那条的
    /// 自动是走 `operate=auto` 试出来的，预约这条的 `operate` 抓包里只见过 `manual`）。
    enum Mode: String, CaseIterable, Sendable {
        case cold
        case hot

        var label: String {
            switch self {
            case .cold: "制冷"
            case .hot: "制热"
            }
        }
    }

    static let minTemperature = 18
    static let maxTemperature = 32

    var hour: Int = 7
    var minute: Int = 30
    /// 协议编码（0 = 周日），见 `AppointmentWeekday`。空集合 = 仅一次。
    var days: Set<Int> = AppointmentWeekday.workdays
    var temperature: Int = 24
    var mode: Mode = .hot
    /// 车上已有那条预约的 id。改已有预约时沿用，新建时为 nil、下发时现造。
    var setID: String?

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var summary: String {
        "\(AppointmentWeekday.summary(days)) \(timeText) · \(mode.label) \(temperature) ℃"
    }

    /// 下一次到点的时刻。`start_time` 带日期，一次性预约（`days` 空）必须落在将来——
    /// 今天这个钟点已经过了就往后推一天，不然下发的是一个已经过去的时间。
    func nextStart(after now: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        let today = calendar.date(from: components) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    // MARK: - 回读

    /// 从 `getappointment` 回读的 `controls[]` 里取第一条开着的预约。
    ///
    /// `controls` 为空（官方取消之后回读就是这样）或者里面没有 `on == "1"` 的项，返回 nil——
    /// 那是「车上没有预约」，不是「读不到」，调用方要分清。
    static func parse(controls: [JSONValue]) -> ClimateAppointment? {
        for item in controls {
            guard let object = item.objectValue else { continue }
            guard object["on"]?.stringValue == "1" else { continue }
            guard let start = object["start_time"]?.stringValue,
                  let (hour, minute) = Self.clock(from: start) else { continue }
            let days = Set((object["days"]?.arrayValue ?? []).compactMap(\.intValue))
            let temperature = object["temperature"]?.intValue ?? 24
            return ClimateAppointment(
                hour: hour,
                minute: minute,
                days: days,
                temperature: min(maxTemperature, max(minTemperature, temperature)),
                mode: Mode(rawValue: object["mode"]?.stringValue ?? "") ?? .hot,
                setID: object["set_id"]?.stringValue
            )
        }
        return nil
    }

    /// `"2026-10-22 19:54:00"` → (19, 54)。
    static func clock(from startTime: String) -> (Int, Int)? {
        let parts = startTime.split(separator: " ")
        guard let time = parts.last else { return nil }
        let hm = time.split(separator: ":")
        guard hm.count >= 2, let hour = Int(hm[0]), let minute = Int(hm[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// `getappointment` 的 `data` 是一段 **JSON 字符串**，里面才是 `{"controls":[...]}`。
    /// 也兼容网关哪天直接回对象。解析不出返回 nil（= 读不到，不是「没有预约」）。
    static func controls(fromAppointmentData data: JSONValue?) -> [JSONValue]? {
        guard let data else { return nil }
        if let object = data.objectValue {
            return object["controls"]?.arrayValue ?? []
        }
        guard let text = data.stringValue, !text.isEmpty,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        return decoded["controls"]?.arrayValue ?? []
    }
}

extension LeapCommand {
    /// 预约空调。cmdid 171，走预约端点（`appointmentCmdIds` 里本来就有 171）。
    ///
    /// 字段值全用字符串（`on` / `temperature` / `windlevel` 等），`days` 是整数数组——
    /// 照官方抓包 `[681]` 的形态，不自作主张统一类型。
    static func climateAppointment(
        _ appointment: ClimateAppointment,
        vin: String,
        now: Date = .now
    ) -> LeapCommand {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let millis = Int(now.timeIntervalSince1970 * 1000)
        let control: [String: Any] = [
            "circle": "in",
            "days": appointment.days.sorted(),
            "mode": appointment.mode.rawValue,
            "on": "1",
            "operate": "manual",
            "position": "all",
            "set_id": appointment.setID ?? "iOS_\(vin)_\(millis)",
            "start_time": formatter.string(from: appointment.nextStart(after: now)),
            "temperature": String(min(ClimateAppointment.maxTemperature,
                                      max(ClimateAppointment.minTemperature, appointment.temperature))),
            "update_time": "\(millis)",
            "windlevel": "7",
            "wshld": "1"
        ]
        let data = try? JSONSerialization.data(withJSONObject: ["controls": [control]], options: [.sortedKeys])
        let state = data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"controls":[]}"#
        return LeapCommand(cmdid: "171", stateJSON: state, label: "预约空调")
    }

    /// 取消预约空调：**发空的 `controls`**，不是发一条 `on: "0"` 的预约项。
    /// 官方取消抓包 `cancel/[332]` 就是这样，随后回读 `[334]` 拿到的也是空 `controls`。
    static func cancelClimateAppointment() -> LeapCommand {
        LeapCommand(cmdid: "171", stateJSON: #"{"controls":[]}"#, label: "取消预约空调")
    }
}
