import Compression
import Foundation

/// 够用就好的 ZIP 解包器。
///
/// 零跑的车模型包（模型 10MB / 渲染器 4MB）只用了 Stored 和 DEFLATE 两种方法，
/// 没有加密、没有 ZIP64。系统 `Compression` 框架的 `ZLIB` 算法解的正是 ZIP 用的
/// raw DEFLATE，所以不必为这一个功能引第三方库——这个工程的 pbxproj 是手工维护的，
/// 加依赖的代价比这一百来行高。
///
/// 只认标准布局：从尾部找 EOCD → 读中央目录 → 按 local header 定位数据。
/// 遇到任何不认识的结构就整包失败，交给上层回退 2D，不做半解压。
enum ZipArchive {
    enum Failure: Error {
        case notAZip
        case unsupportedEntry(String)
        case corrupted(String)
    }

    /// 解压到 `destination`。目录会按需创建；已存在的同名文件覆盖。
    static func extract(_ data: Data, to destination: URL) throws {
        let entries = try readCentralDirectory(data)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            // 防 zip slip：解出来的路径必须还在 destination 里。
            guard let target = safeURL(for: entry.name, under: destination) else {
                throw Failure.unsupportedEntry(entry.name)
            }
            if entry.name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let payload = try payload(of: entry, in: data)
            try payload.write(to: target, options: .atomic)
        }
    }

    // MARK: - 结构

    private struct Entry {
        var name: String
        var compressionMethod: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// 从尾部回扫 EOCD 签名。注释最长 65535，所以最多回看这么多。
    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        let eocdSignature: UInt32 = 0x0605_4B50
        let minEOCD = 22
        guard data.count >= minEOCD else { throw Failure.notAZip }
        let searchFloor = max(0, data.count - minEOCD - 65_535)
        var eocd: Int?
        var index = data.count - minEOCD
        while index >= searchFloor {
            if read32(data, at: index) == eocdSignature { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw Failure.notAZip }

        let count = Int(read16(data, at: eocd + 10))
        var cursor = Int(read32(data, at: eocd + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard cursor + 46 <= data.count, read32(data, at: cursor) == 0x0201_4B50 else {
                throw Failure.corrupted("中央目录项损坏")
            }
            let method = read16(data, at: cursor + 10)
            let compressed = Int(read32(data, at: cursor + 20))
            let uncompressed = Int(read32(data, at: cursor + 24))
            let nameLength = Int(read16(data, at: cursor + 28))
            let extraLength = Int(read16(data, at: cursor + 30))
            let commentLength = Int(read16(data, at: cursor + 32))
            let localOffset = Int(read32(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw Failure.corrupted("文件名越界")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            // 包里有 GBK 命名的 CSV，UTF-8 解不出来时退到 GB18030，再不行才放弃。
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: gb18030)
                ?? ""
            guard !name.isEmpty else { throw Failure.corrupted("文件名无法解码") }
            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    )

    /// local header 的 name/extra 长度可能与中央目录不同，必须以 local 的为准定位数据。
    private static func payload(of entry: Entry, in data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, read32(data, at: base) == 0x0403_4B50 else {
            throw Failure.corrupted("local header 损坏：\(entry.name)")
        }
        let nameLength = Int(read16(data, at: base + 26))
        let extraLength = Int(read16(data, at: base + 28))
        let start = base + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw Failure.corrupted("数据越界：\(entry.name)") }
        let raw = data.subdata(in: start..<end)

        switch entry.compressionMethod {
        case 0:
            return raw
        case 8:
            guard let inflated = inflate(raw, expecting: entry.uncompressedSize) else {
                throw Failure.corrupted("解压失败：\(entry.name)")
            }
            return inflated
        default:
            throw Failure.unsupportedEntry(entry.name)
        }
    }

    /// raw DEFLATE 解压。`compression_decode_buffer` 一次成型，
    /// 目标缓冲按中央目录里的原始大小开——ZIP 里这个值是可信的。
    private static func inflate(_ data: Data, expecting size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { return nil }
        return output
    }

    /// 拒绝 `../` 和绝对路径，避免恶意包写到解压目录之外。
    private static func safeURL(for name: String, under root: URL) -> URL? {
        let components = name.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              !name.hasPrefix("/") else { return nil }
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    // MARK: - 小端读取

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }
}
