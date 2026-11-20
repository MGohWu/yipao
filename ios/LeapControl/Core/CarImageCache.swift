import UIKit

/// 叠好的车图缓存。
///
/// 图层包解压在 Caches 里，冷启动时重新叠一次要读七八张 1125×525 的 PNG，
/// 在首页第一帧之前做不完——那一下就会闪一次剪影。所以把叠好的成品也存一张，
/// 启动时**同步**读它先顶上，等真实车况回来再叠新的覆盖。
enum CarImageCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CarModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// vin 里的斜杠等一律替换成下划线，避免拼出子路径。
    private static func fileURL(vin: String) -> URL {
        let safe = String(vin.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return directory.appendingPathComponent("car-\(safe).png")
    }

    /// 同步读上次那张，给启动第一帧用。
    static func cached(vin: String) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(vin: vin)) else { return nil }
        return UIImage(data: data)
    }

    static func store(_ image: UIImage, vin: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: fileURL(vin: vin), options: .atomic)
    }

    // MARK: - 卡片用的那一份

    /// 卡片读的车图放在 App Group 里，**不是**上面那个目录。
    ///
    /// 上面用的是 App 自己的 Caches，扩展进程是另一个容器，压根看不见。
    /// 这里只存当前这台车的一张：卡片本来就只显示当前车（快照也是这么定的）。
    private static var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SnapshotStore.appGroup)?
            .appendingPathComponent("car-widget.png")
    }

    /// 给卡片写一份：裁掉四周的透明边，再缩到卡片用得上的尺寸。
    ///
    /// 官方图层是 1125×525 的宽幅画布，车只占中间一条，四周是透明留白。
    /// 原样丢进 158pt 见方的小卡里，车会缩成中间细细一道；而且卡片进程的内存预算很紧，
    /// 没必要让它每次渲染都去解一张几百 KB 的大图。
    @discardableResult
    static func storeShared(_ image: UIImage) -> Bool {
        store(shared: image, requireTransparentBorder: false)
    }

    /// 3D 渲染器截来的那张。
    ///
    /// 和图层叠出来的不一样：它有可能整张都不透明——WebGL 的背景没抠干净、
    /// 或者快照落进了不透明上下文，都会这样。那种图写进卡片就是一整块底色，
    /// 比剪影更难看。所以要求四周留有透明边，验不过宁可不写。
    @discardableResult
    static func storeShared(rendered image: UIImage) -> Bool {
        store(shared: image, requireTransparentBorder: true)
    }

    private static func store(shared image: UIImage, requireTransparentBorder: Bool) -> Bool {
        guard let sharedFileURL,
              let trimmed = trimmedAndScaled(
                  image, maxWidth: 480, requireTransparentBorder: requireTransparentBorder
              ),
              let data = trimmed.pngData() else { return false }
        do {
            try data.write(to: sharedFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func shared() -> UIImage? {
        guard let sharedFileURL, let data = try? Data(contentsOf: sharedFileURL) else { return nil }
        return UIImage(data: data)
    }

    /// 退出登录、换车、关掉「显示车模型」都要清——否则卡片上会一直挂着上一台车。
    static func clearShared() {
        guard let sharedFileURL else { return }
        try? FileManager.default.removeItem(at: sharedFileURL)
    }

    /// 按 alpha 求出内容的外接矩形，裁掉透明边后等比缩放。
    /// 全透明（叠图失败）时返回 nil，宁可让卡片退回剪影，也别写一张空图上去。
    ///
    /// `requireTransparentBorder` 要求内容四周都至少留一像素透明边，留不出就返回 nil。
    /// 它是「这张图的背景真的抠掉了吗」的判据：整张不透明时外接矩形正好等于画布本身。
    private static func trimmedAndScaled(
        _ image: UIImage, maxWidth: CGFloat, requireTransparentBorder: Bool = false
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // 只取 alpha 通道扫一遍，比拉出整张 RGBA 省一大截内存。
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = alpha.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        }) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 低于这个值的像素当成透明：图层边缘做过羽化，纯 0 的判据会把羽化带也留下来。
        let threshold: UInt8 = 8
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        if requireTransparentBorder {
            guard minX > 0, minY > 0, maxX < width - 1, maxY < height - 1 else { return nil }
        }

        let cropped = cgImage.cropping(to: CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
        ))
        guard let cropped else { return nil }

        let scale = min(1, maxWidth / CGFloat(cropped.width))
        let target = CGSize(
            width: (CGFloat(cropped.width) * scale).rounded(),
            height: (CGFloat(cropped.height) * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        // 1 倍出图：这张已经是按像素算好的目标尺寸，再乘一次屏幕倍率纯属浪费。
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
