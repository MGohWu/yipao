import UIKit

/// 2D 车的分层贴图合成。
///
/// 没有 3D 的车型（S01、C10…）在 `carpicture/key/package` 里给的不是模型，
/// 而是一整套 1125×525 的图层：车身打底，门、引擎盖、尾门、充电各一层，
/// 官方爱车页就是把它们按车况叠出来的——所以那张图会跟着车动。
///
/// **叠加顺序不是猜的**，来自官方三处对照：
/// - `res/layout/lpcar_car_model.xml` —— RelativeLayout 子节点顺序就是 z 序
/// - `LPCarStateViewManager.OooO00o(state, iv1…iv15)` —— 谁在什么车况下显示、用哪张图
/// - `FragmentCarModelBinding` —— 把 iv1…iv15 和布局里的 view id 对上
///
/// 对上之后才发现两件容易叠错的事：**右侧的门和尾门画在车身下面**（那一侧本来
/// 就被车身挡住），以及**充电层的 z 位置按车型不同**（官方在布局里备了三个槽）。
///
/// 官方布局里还留着空调 ×3、轮毂、加热灯、行车灯六个 ImageView，但 1.22.87
/// 全 App 没有一行代码给它们 setImage——加密字符串表里连 `carpic_ac_*`、
/// `carpic_wheel*`、`carpic_frontrunning_*`、`carpic_heatlight_*` 都不存在。
/// 包里那些图是给别的版本备着的，我们也不叠，保持和官方一致。
enum CarLayerComposer {
    /// 图层目录（解压后的 `android/xxhdpi`）。
    static func layerDirectory(in root: URL) -> URL? {
        let fm = FileManager.default
        // 包里是 android/<density>/，密度目录名各车型可能不同，取第一个有 PNG 的。
        let android = root.appendingPathComponent("android", isDirectory: true)
        guard let densities = try? fm.contentsOfDirectory(at: android, includingPropertiesForKeys: nil)
        else { return nil }
        return densities.first { dir in
            (try? fm.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasSuffix(".png") } == true
        }
    }

    // MARK: - 车型分组

    /// 门窗规则的分组，对应 `CarStateViewController` 里的分支。
    ///
    /// 车型码取自 `CarDataUtil.sCarTypes`：s01 t03 a05 a10 b11 b10 b01 b05
    /// c01 c11 c10 c16 d19 d21 d99。注意官方 `isC10Car()` 把 `b11` 也算 c10。
    private enum DoorRule {
        /// C11 和所有未列名车型：四门齐全，不补窗层，尾门恒显示。
        case fullDoors
        /// c10 / b11 / c01 / c16 / b10 / b01：四门齐全，门关时补一层窗。
        case fullDoorsWithWindows
        /// t03：同上，但尾门只在开着时画。
        case t03
        /// s01：两门轿跑，没有后门和后窗，尾门只在开着时画。
        case s01

        /// 前缀匹配，判据统一走 `CarTypeFamily`：carType 带上年款之类的后缀时，
        /// 原来的精确匹配会让 `T03-2023` 静悄悄落进 `default`，按 C11 那套画门窗。
        /// 分支的先后顺序保持和原来的 switch 一致。
        init(carType: String) {
            if CarTypeFamily.isS01(carType) {
                self = .s01
            } else if CarTypeFamily.isT03(carType) {
                self = .t03
            } else if CarTypeFamily.matches(carType, anyOf: ["c10", "b11", "c01", "c16", "b10", "b01"]) {
                self = .fullDoorsWithWindows
            } else {
                self = .fullDoors  // c11 和其余车型走同一套
            }
        }
    }

    /// 充电层的 z 槽位。官方在布局里备了三个，按车型选一个用——
    /// 分组和门窗那套**不一样**（b01 门窗跟 c10，充电跟 c11）。
    private enum ChargeSlot {
        /// `newchargingAnimate`：车身**下面**。c11 / c01 / b10 / b01 和未列名车型。
        case belowBody
        /// `chargingAnimate`：车身上面、左后门下面。c16 / c10（含 b11）。
        case aboveBody
        /// `ivChargeAnimateOuter`：所有门之上。t03 / s01。
        case aboveDoors

        init(carType: String) {
            if CarTypeFamily.matches(carType, anyOf: ["c16", "c10", "b11"]) {
                self = .aboveBody
            } else if CarTypeFamily.isLegacyFamily(carType) {  // t03 / s01
                self = .aboveDoors
            } else {
                self = .belowBody
            }
        }
    }

    // MARK: - 图层方案

    /// 一次合成要用到的图层，按 z 序从下往上分三段。
    ///
    /// 中间那段是充电动画：0 张表示不画，1 张是静态图，多张按 ``frameInterval``
    /// 循环播放。分三段是因为充电层夹在中间——底和顶可以各合成一张静态图，
    /// 只有中间这段需要逐帧换。
    struct LayerPlan: Equatable {
        var below: [String] = []
        var chargeFrames: [String] = []
        var above: [String] = []

        var isAnimated: Bool { chargeFrames.count > 1 }
        var signature: String {
            (below + ["#"] + chargeFrames + ["#"] + above).joined(separator: "|")
        }
    }

    /// 官方帧间隔：`startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`。
    static let frameInterval: TimeInterval = 0.11

    /// 按车况和车型排出图层方案。
    static func plan(for state: VehicleState?, carType: String) -> LayerPlan {
        let doors = DoorRule(carType: carType)
        let slot = ChargeSlot(carType: carType)

        var plan = LayerPlan()
        // 充电槽之前写 below、之后写 above，一次遍历就分好段。
        var reachedCharge = false
        func put(_ name: String) {
            if reachedCharge { plan.above.append(name) } else { plan.below.append(name) }
        }

        let leftFrontOpen = state?.bool(.driverDoor) == true
        let rightFrontOpen = state?.bool(.passengerDoor) == true
        let leftRearOpen = state?.bool(.leftRearDoor) == true
        let rightRearOpen = state?.bool(.rightRearDoor) == true
        // 官方这个字段叫 isTrunkLock，但用法是 `isTrunkLock ? tailgate_open : tailgate_close`，
        // 说的其实是尾门开着。
        let trunkOpen = state?.trunkOpen == true

        // ① 天幕。见 `skyLayerName` 的说明：判据我们拿不到，暂时不画。
        if let sky = skyLayerName(for: state) { put(sky) }

        // ② 右前门。这一侧朝向观众的背面，官方把它画在车身下面。
        put(rightFrontOpen ? "carpic_rightfront_open" : "carpic_rightfront_close")

        // ③ 右后门。两门轿跑没有。
        if doors != .s01 {
            put(rightRearOpen ? "carpic_rightbehind_open" : "carpic_rightbehind_close")
        }

        // ④ 尾门。t03/s01 只在开着时画（包里也只有 open 那张），其余恒画。
        switch doors {
        case .t03, .s01:
            if trunkOpen { put("carpic_tailgate_open") }
        case .fullDoors, .fullDoorsWithWindows:
            put(trunkOpen ? "carpic_tailgate_open" : "carpic_tailgate_close")
        }

        if slot == .belowBody { reachedCharge = true }

        // ⑤ 车身 + 引擎盖。引擎盖没有独立信号，官方也一律按关闭画。
        put("carpic_body")
        put("carpic_hood_close")

        // ⑥ 车窗补层。名字里的 close 说的是「门关着时那扇窗」——
        // 门开时用的是门的 open 图，里面自带窗，再叠这层会重影。
        // 所以它跟车窗开度无关，只看门。
        if doors == .fullDoorsWithWindows || doors == .t03 {
            if !leftFrontOpen { put("carpic_leftfront_window_close") }
            if !leftRearOpen { put("carpic_leftbehind_window_close") }
        }

        if slot == .aboveBody { reachedCharge = true }

        // ⑦ 左侧的门。这一侧朝向观众，画在车身上面。
        if doors != .s01 {
            put(leftRearOpen ? "carpic_leftbehind_open" : "carpic_leftbehind_close")
        }
        put(leftFrontOpen ? "carpic_leftfront_open" : "carpic_leftfront_close")

        if slot == .aboveDoors { reachedCharge = true }

        // ⑧ 充电。行车中官方整层隐藏。
        if state?.isDriving != true {
            plan.chargeFrames = chargeFrames(for: state, carType: carType)
        }

        // ⑨ 充电口盖。只有 t03/s01 画，且跟着充电层一起显示或隐藏。
        if slot == .aboveDoors, !plan.chargeFrames.isEmpty {
            plan.above.append("carpic_charge_open")
        }

        // ⑩ 车窗告警标签。同 ①，判据缺失。
        if let alarm = windowAlarmLayerName(for: state) { plan.above.append(alarm) }

        return plan
    }

    /// 充电层的帧。
    ///
    /// 官方 `startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`：从
    /// `carpic_charge2` 起连着取 n 张，每张 110ms 循环，缺哪张就在那停。
    /// n 按车型不同：s01 = 18、t03 = 14、其余 = 15。
    ///
    /// 不充电时按 `chargeState` 出一张静态图（`carpic_charge1` 是插枪待机、
    /// `carpic_charge2` 是充满）。
    private static func chargeFrames(for state: VehicleState?, carType: String) -> [String] {
        switch state?.chargeState {
        case 1:
            let count: Int
            if CarTypeFamily.isS01(carType) {
                count = 18
            } else if CarTypeFamily.isT03(carType) {
                count = 14
            } else {
                count = 15
            }
            return (0..<count).map { "carpic_charge\($0 + 2)" }
        case 3, 4, 6: return ["carpic_charge1"]
        case 2: return ["carpic_charge2"]
        default: return []
        }
    }

    /// 天幕状态标签（`carpic_windowstatus_top_green` / `_top_red`）。
    ///
    /// 官方判据是 `newSkystate` 加防盗状态 `isCarPrevent`，两个信号我们都没有，
    /// 而且这层是张写着中文的标签图、不是车体的一部分——首页那排徽章已经在播报
    /// 同样的事。等拿到信号再决定要不要接。
    private static func skyLayerName(for state: VehicleState?) -> String? { nil }

    /// 车窗告警标签（绿「车窗已开」/ 红「车窗未关」）。
    ///
    /// 绿红之分看的是钥匙位置 ON1（`isOn1Open`）——人在车上开窗是绿，熄火离车
    /// 还开着是红。这个信号我们读不到，猜错就是在车图上写一句错话，所以不画。
    private static func windowAlarmLayerName(for state: VehicleState?) -> String? { nil }

    // MARK: - 合成

    /// 叠好的车图。充电动画时 ``chargeFrames`` 有多张，界面逐帧切换。
    struct ComposedCar {
        /// 充电层以下（含车身）叠好的一张。
        var base: UIImage
        /// 充电层。空表示不画，一张是静态，多张循环播放。
        var chargeFrames: [UIImage] = []
        /// 充电层以上（充电口盖等）叠好的一张，没有就是 nil。
        var top: UIImage?

        var isAnimated: Bool { chargeFrames.count > 1 }

        /// 拍平成一张静态图，给桌面卡片用。
        ///
        /// 卡片里播不了逐帧动画，也不该播——充电线一段段亮起来那套是首页的效果。
        /// 但充电层的**静态**那张（插枪待机 / 已充满）要留，不然插着枪的车在卡片上
        /// 看起来像没插。底/顶两段共用同一块画布，按同一个矩形画上去就自动对齐。
        var still: UIImage {
            let canvas = base.size
            let format = UIGraphicsImageRendererFormat()
            format.scale = base.scale
            format.opaque = false
            return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                let rect = CGRect(origin: .zero, size: canvas)
                base.draw(in: rect)
                if !isAnimated { chargeFrames.first?.draw(in: rect) }
                top?.draw(in: rect)
            }
        }
    }

    /// 把图层按方案叠出来。缺失的图层跳过；车身那张都读不到返回 nil。
    static func compose(state: VehicleState?, carType: String, layerDirectory: URL) -> ComposedCar? {
        // 画布尺寸一律以车身那张为准。分层图**不保证同尺寸**——同一个包里行车灯就是
        // 1125×1200 而车身是 1125×525。而且底/顶两段是分开渲染的，画布不统一的话
        // 它们各自 scaledToFit 之后会对不齐，车图两侧会多出一圈边。
        guard let body = load("carpic_body", in: layerDirectory) else { return nil }
        let canvas = body.size
        let plan = plan(for: state, carType: carType)
        guard let base = flatten(plan.below, in: layerDirectory, canvas: canvas) else { return nil }
        return ComposedCar(
            // 充电层不用羽化：它画的是车身中部的充电线，够不着画布边缘，
            // 而它有 14–18 帧，每帧都重绘一遍纯属白给。
            base: feathered(base),
            chargeFrames: plan.chargeFrames.compactMap {
                load($0, in: layerDirectory).map { fit($0, to: canvas) }
            },
            top: flatten(plan.above, in: layerDirectory, canvas: canvas).map(feathered)
        )
    }

    // MARK: - 边缘羽化

    /// 羽化区宽度占画布宽度的比例。
    ///
    /// 官方图层在画布左右边缘留了**不透明的环境像素**，而且不同车型留的还不是
    /// 一种东西——实测两台 C11：
    /// - 白色那台：接地阴影是一条横贯全宽的暗带，铺到画布边缘时还有约 10% 不透明度，
    ///   然后被画布一刀切断，在地面高度留下两条竖直硬边；
    /// - 黑色那台：左右各一条纯白柔光柱，外缘 255 向内线性衰减到 0，跨度正好 10% 图宽。
    ///
    /// 官方爱车页底色是浅灰，这些东西全藏在背景里；我们的背景是渐变蓝/深色，它们
    /// 就成了两道扎眼的竖边。没法逐车型枚举，统一按比例羽化掉最外一圈。
    ///
    /// 10% 是量出来的：白柱正好这么宽，而车体离画布边缘还有 16% 以上（白车 17%、
    /// 黑车 16%），羽化吃不到车。真要有车型把车画得更靠边，宁可车头淡一点，
    /// 也好过挂两根柱子。
    private static let featherRatio: CGFloat = 0.1

    /// 把图的左右两侧按 ``featherRatio`` 渐隐到全透明。
    ///
    /// 只做水平方向：上下边缘官方图留了足够留白，没见过被切的。
    private static func feathered(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // 和 draw 一致：图本身就是 @3x 尺寸，别再乘屏幕倍率
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(at: .zero)
            // destinationIn：只保留渐变里 alpha 不为 0 的部分，等价于给图套一层遮罩。
            context.cgContext.setBlendMode(.destinationIn)
            guard let gradient = featherGradient() else { return }
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: []
            )
        }
    }

    /// 两端渐隐、中间全实的遮罩渐变。
    ///
    /// 用 smoothstep 采样而不是直线：线性渐隐在羽化区内侧会留下一道能看出来的
    /// 折线（斜率突变），smoothstep 两端斜率为 0，接得上。
    private static func featherGradient() -> CGGradient? {
        let steps = 8
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let alpha = t * t * (3 - 2 * t)  // smoothstep
            // 左侧升、右侧降，中间那段保持全实。
            colors.append(UIColor(white: 1, alpha: alpha).cgColor)
            locations.append(t * featherRatio)
            colors.append(UIColor(white: 1, alpha: 1 - alpha).cgColor)
            locations.append(1 - featherRatio + t * featherRatio)
        }
        // 上面是左右交替追加的，得按位置排回去。
        let sorted = zip(locations, colors).sorted { $0.0 < $1.0 }
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: sorted.map(\.1) as CFArray,
            locations: sorted.map(\.0)
        )
    }

    private static func load(_ name: String, in directory: URL) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent("\(name).png").path)
    }

    private static func flatten(_ names: [String], in directory: URL, canvas: CGSize) -> UIImage? {
        let images = names.compactMap { load($0, in: directory) }
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return fit(first, to: canvas) }
        return draw(images, canvas: canvas)
    }

    /// 尺寸已经对得上就原样用，省一次重绘。
    private static func fit(_ image: UIImage, to canvas: CGSize) -> UIImage {
        image.size == canvas ? image : (draw([image], canvas: canvas) ?? image)
    }

    private static func draw(_ images: [UIImage], canvas: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // 图本身就是 @3x 尺寸，再乘一遍屏幕倍率会白白吃几十 MB 内存
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            for image in images {
                image.draw(in: CGRect(origin: .zero, size: canvas))
            }
        }
    }
}
