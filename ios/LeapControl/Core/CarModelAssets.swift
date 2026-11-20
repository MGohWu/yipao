import Foundation

/// 3D 车模型的本地资源目录：下载两个 ZIP、解压、按车缓存。
///
/// 目录布局照着渲染器的相对路径来——渲染器包里的 `index.js` 用
/// `./C11_2026/C11_2026_full_car.fbx` 这样的相对路径取模型，所以模型包必须
/// 解到渲染器同一级：
///
///     <Caches>/CarModel3D/<vin>/
///       ├─ index.html / index.js / FBX.worker.js / models/ / textures/   ← 渲染器包
///       └─ C11_2026/…                                                    ← 模型包
///
/// 一辆车约 14MB，放 Caches：系统缺空间时可以回收，回收了下次自动重下。
enum CarModelAssets {
    /// 解压完成的标记。两个包都解开才写，避免半成品被当成可用。
    private static let readyMarker = ".ready"

    static func directory(vin: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("CarModel3D", isDirectory: true)
            .appendingPathComponent(sanitize(vin), isDirectory: true)
    }

    private static func sanitize(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// 3D 资源是否已就绪。顺带校验入口文件还在——Caches 可能被系统清掉一部分。
    static func isReady(vin: String) -> Bool {
        let dir = directory(vin: vin)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(readyMarker).path)
            && fm.fileExists(atPath: dir.appendingPathComponent("index.html").path)
    }

    /// 2D 图层包是否已就绪。
    static func areLayersReady(vin: String) -> Bool {
        let dir = directory(vin: vin)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(readyMarker).path)
            && CarLayerComposer.layerDirectory(in: dir) != nil
    }

    /// 准备 2D 图层包。没有 3D 的车型（S01、C10…）用 `srcKey` 换到的是这一套图层，
    /// 官方爱车页那张会跟着车况变的图就是它叠出来的。
    static func prepareLayers(
        vin: String,
        model: CarModel,
        download: (String) async throws -> Data
    ) async throws -> URL {
        let dir = directory(vin: vin)
        if areLayersReady(vin: vin) { return dir }

        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let payload = try await download(model.srcKey)
        try ZipArchive.extract(payload, to: dir)
        guard CarLayerComposer.layerDirectory(in: dir) != nil else {
            try? fm.removeItem(at: dir)
            throw ZipArchive.Failure.corrupted("图层包里没有 android/<density> 目录")
        }
        fm.createFile(atPath: dir.appendingPathComponent(readyMarker).path, contents: Data())
        return dir
    }

    /// 准备资源：已就绪直接返回目录；否则下载两个包解压。
    ///
    /// `download` 由调用方注入（`LeapClient.fetchCarModelPackage`），
    /// 这样这里不依赖网络层，测试时也能塞本地包。
    static func prepare(
        vin: String,
        model: CarModel,
        download: (String) async throws -> Data
    ) async throws -> URL {
        let dir = directory(vin: vin)
        if isReady(vin: vin) { return dir }

        let fm = FileManager.default
        // 上次可能解到一半就被杀了，重来一遍前先清干净。
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 渲染器包在外层，模型包解进去后正好是它的同级子目录。
        let h5 = try await download(model.h5Key)
        try ZipArchive.extract(h5, to: dir)
        let source = try await download(model.srcKey)
        try ZipArchive.extract(source, to: dir)

        guard fm.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            try? fm.removeItem(at: dir)
            throw ZipArchive.Failure.corrupted("渲染器包里没有 index.html")
        }
        fm.createFile(atPath: dir.appendingPathComponent(readyMarker).path, contents: Data())
        return dir
    }

    /// 从解压出来的目录名反推车型别名，`Lafa5_2026/` → `Lafa5`。
    ///
    /// 存在的理由：渲染器按 `<别名>_<年款>/` 取资源，而别名不一定等于 `carType`。
    /// B05 的资源目录叫 `Lafa5_2026`（Lafa5 是它的内部代号），按 carType 拼必然 404。
    /// 接口的 `modelParam` 里没有这个别名——只有 carType/carTypeCode/colorCode/year 四项，
    /// 所以唯一可靠的来源就是包自己解出来的目录名。这样新车型不用维护映射表。
    ///
    /// 渲染器缺省的 `"lafa5"` 顶不上：**iOS 的 APFS 大小写敏感**，`lafa5_2026` 命不中
    /// `Lafa5_2026`，实测就是这么 404 的。必须按目录名原样传。
    ///
    /// B05 会同时解出 `Lafa5_2026` 和 `Lafa5Ultra_2026` 两套，靠 `carTypeCode` 里
    /// 有没有 `ultra` 区分——和渲染器 `confirmVehicleLoad` 自己那段特判同一个判据。
    static func assetAlias(in root: URL, carTypeCode: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let names = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            // `<名字>_<四位年款>`。渲染器自带的 models/、textures/ 不长这样，自然被滤掉。
            .filter { name in
                guard let separator = name.lastIndex(of: "_") else { return false }
                let year = name[name.index(after: separator)...]
                return year.count == 4 && year.allSatisfy(\.isNumber) && separator != name.startIndex
            }
            .map { String($0[$0.startIndex..<$0.lastIndex(of: "_")!]) }
        guard !names.isEmpty else { return nil }

        let wantsUltra = carTypeCode.lowercased().contains("ultra")
        let matched = names.filter { $0.lowercased().contains("ultra") == wantsUltra }
        // 挑不出对应版本就退回任意一个：拼错版本也比拼一个必然 404 的 carType 强。
        return matched.first ?? names.first
    }

    /// 换车或换车型版本时清掉旧资源。
    static func clear(vin: String) {
        try? FileManager.default.removeItem(at: directory(vin: vin))
    }
}
