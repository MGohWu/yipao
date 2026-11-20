import Foundation

/// 服务端返回的结构在不同接口之间差异很大，且会随 App 版本变化。
/// 这里用一个可 Sendable 的动态 JSON 表示，配合深度查找，避免为每个接口硬写模型。
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 节点")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// 排查用的可读文本。键排序，方便两次响应直接对比。
    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "(无法序列化)"
        }
        return text
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let dict) = self else { return nil }
        return dict
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    /// 数字、布尔、字符串统一转成字符串，方便直接参与签名和展示。
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .null, .object, .array: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    /// 深度优先查找第一个满足条件的对象节点。
    func firstObject(where predicate: ([String: JSONValue]) -> Bool) -> [String: JSONValue]? {
        if case .object(let dict) = self {
            if predicate(dict) { return dict }
            for value in dict.values {
                if let found = value.firstObject(where: predicate) { return found }
            }
        }
        if case .array(let items) = self {
            for item in items {
                if let found = item.firstObject(where: predicate) { return found }
            }
        }
        return nil
    }

    /// 收集所有满足条件的对象节点。
    func allObjects(where predicate: ([String: JSONValue]) -> Bool) -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        if case .object(let dict) = self {
            if predicate(dict) { out.append(dict) }
            for value in dict.values { out.append(contentsOf: value.allObjects(where: predicate)) }
        }
        if case .array(let items) = self {
            for item in items { out.append(contentsOf: item.allObjects(where: predicate)) }
        }
        return out
    }

    /// 接口返回码：code / result / status 任一存在即可。
    var responseCode: String? {
        for key in ["code", "result", "status"] {
            if let value = self[key]?.stringValue { return value }
        }
        return nil
    }

    var responseMessage: String {
        for key in ["msg", "message", "error"] {
            if let value = self[key]?.stringValue, !value.isEmpty { return value }
        }
        return ""
    }

    var isSuccess: Bool {
        if self["success"] == .bool(true) { return true }
        guard let code = responseCode else { return true }
        return code == "0" || code == "200"
    }
}
