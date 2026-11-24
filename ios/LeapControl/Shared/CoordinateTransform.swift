import CoreLocation
import Foundation

/// GCJ-02 ↔ WGS-84 换算。**用错方向比不转更糟，改之前先读完这段。**
///
/// **全端只有两个坐标口径，且出口只有两处，一进一出各一次：**
///
/// - 车：车端原始值 →（`VehicleState.shareableCoordinate`）→ GCJ-02 → 地图/距离/跳转。
///   车端同帧上报的几组经纬度**不是同一套**：`2`/`3` 是车机转好的 GCJ-02，
///   `3724`/`3725`、`2190`/`2191` 是原始 WGS-84（判据的算术过程写在
///   `SignalSchema.numeric` 的 `.longitude` 那段）。
/// - 手机：`CLLocationManager` 的 WGS-84 →（`UserLocationProvider.coordinate`）→ GCJ-02。
///   国内地图底图（苹果 MapKit、高德、百度、腾讯）全是 GCJ-02，`CLLocationManager`
///   **在大陆吐的仍然是 GPS 原始坐标**，必须转一次才能和车标放在同一张图上。
///
/// 下游任何地方再转一次都是错的。`wgs84(fromGCJ02:)` 目前**没有生产调用方**，
/// 留着是为了外接 GPS 设备之类的场合（以及给 `CLGeocoder` 那类只吃 WGS-84 的接口）。
///
/// **这个坑踩过三次，代价都是全体用户或「定位永远差半条街」，别再踩第四次：**
///
/// 1. 2026-08-18（提交 `2364c5b`）：按「MapKit 入参一律 WGS-84、它自己纠偏到 GCJ-02 底图」
///    这条通行说法，把车端 GCJ-02 坐标转成 WGS-84 再交给 MapKit。当天 14:45 打包发出去，
///    第二天**所有**用户都报偏——而在那之前只有一个人报。转换随即回滚。
///    当时用来支撑那条说法的观察是「同一张地图上 `UserAnnotation` 蓝点一直准」。观察没错，
///    但结论下反了：蓝点准是 MapKit 在**画蓝点的时候**自己纠了偏，不代表喂给 MapKit 的
///    坐标会被纠正。所以「蓝点准」既不能证明 CoreLocation 输出是 GCJ-02，也不能证明
///    MapKit 会替你纠偏——它俩各管各的。
///
/// 2. 2026-11-19（1.1 版）：换成「`3724`/`3725` 优先」（见 `SignalSchema.numeric`），
///    理由只是「它与 `2190`/`2191` 互相印证、官方解析器读后者」。可那两组都是原始 GPS，
///    互相印证只说明同源。把 WGS-84 原样喂给 GCJ-02 底图，结果同样是全体偏 500 多米，
///    方向固定、量级固定——这正是坐标系错的形状，而不是「某台车 GPS 漂了」的形状。
///
/// 3. 2026-11-24（1.6 及之前）：车标修好了，手机那一半却一直没转。表现出来不是「整页偏」，
///    而是**只有和手机有关的三样东西偏**：按右上角定位按钮相机落在半条街外、直线距离
///    比实际多出四五百米、高德算路的起点被当成 GCJ-02 传了过去（于是「距离不准」怎么调
///    都调不好）。车标一直是准的，所以看起来像「地图没问题，是距离有问题」。
///
/// **怎么区分这几类问题，下次别再猜：**
/// - 坐标系错：所有人、固定方向、固定几百米，同一帧里几组坐标的差值恰好等于本地
///   WGS-84→GCJ-02 的偏移量。停在地库、熄火很久的旧帧，都不是这个形状。
/// - 信号差：因人因时而异，量级不固定，换个地方停就好了。
/// - 只跟手机有关的量（相机、到车距离）偏，车标不偏：先查手机那一侧转没转。
///
/// 判据必须是实测：同一坐标在苹果地图和高德上落点是否重合，不能靠推理。跨端也对得上——
/// 安卓（高德 SDK）、鸿蒙（华为 Petal）原生吃 GCJ-02，坐标都原样传。
///
enum CoordinateTransform {

    /// 克拉索夫斯基椭球长半轴，GCJ-02 的偏移算法就是按这个椭球定义的。
    private static let semiMajorAxis = 6_378_245.0
    /// 该椭球的第一偏心率平方。
    private static let eccentricitySquared = 0.006_693_421_622_965_943

    /// GCJ-02 → WGS-84。境外坐标原样返回。
    ///
    /// 偏移算法只有正向（WGS-84 → GCJ-02）的闭式解，反向没有，只能迭代逼近：
    /// 拿当前猜测的 WGS-84 正推一次，用推出来的 GCJ-02 和目标的差值去修正猜测。
    /// 偏移量本身随位置变化极缓，这个迭代收敛很快，三轮就到 1e-9 度（约 0.1 毫米）以内，
    /// 这里跑满四轮，纯算术，没有性能顾虑。
    static func wgs84(fromGCJ02 coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(coordinate) else { return coordinate }

        var guess = coordinate
        for _ in 0..<4 {
            let projected = gcj02(fromWGS84: guess)
            guess = CLLocationCoordinate2D(
                latitude: guess.latitude + (coordinate.latitude - projected.latitude),
                longitude: guess.longitude + (coordinate.longitude - projected.longitude)
            )
        }
        return guess
    }

    /// WGS-84 → GCJ-02。境外坐标原样返回。
    ///
    /// **生产调用方只有两个，都在链路的出口上**：`VehicleState.shareableCoordinate`
    /// （车只报了 `3724/3725` 或 `2190/2191` 时）和 `UserLocationProvider.coordinate`
    /// （手机定位）。别再往渲染链路中间加调用点——中间加一次就是「转了两遍」，
    /// 那是偏 1 公里的那种错，比不转还难看。`isInsideChina` 让境外坐标自动跳过转换，
    /// 所以出口处无脑调用是安全的。
    static func gcj02(fromWGS84 coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(coordinate) else { return coordinate }

        let x = coordinate.longitude - 105.0
        let y = coordinate.latitude - 35.0
        var deltaLatitude = latitudeOffset(x: x, y: y)
        var deltaLongitude = longitudeOffset(x: x, y: y)

        let radLatitude = coordinate.latitude * .pi / 180.0
        var magic = sin(radLatitude)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        deltaLatitude = (deltaLatitude * 180.0)
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        deltaLongitude = (deltaLongitude * 180.0)
            / (semiMajorAxis / sqrtMagic * cos(radLatitude) * .pi)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + deltaLatitude,
            longitude: coordinate.longitude + deltaLongitude
        )
    }

    /// 境外不做偏移——GCJ-02 只在大陆范围内和 WGS-84 有差别，出了这个范围两者相等，
    /// 硬转反而会把本来准的坐标推偏几百米。
    ///
    /// **已知局限，不假装它不存在：**这里用的是那个通行的粗矩形，把港澳台和边境线外
    /// 一圈也圈了进去。真正的国界判定要带边界多边形，代价大得多。零跑的车都在大陆卖，
    /// 这个近似的误判区域碰不到；真要处理港澳，得换成按区域的判定，别在这儿加特例。
    private static func isInsideChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= 72.004 && coordinate.longitude <= 137.8347
            && coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271
    }

    /// 偏移算法里的两个多项式。系数没有可读的来历，是算法本身的定义，照抄不要改。
    private static func latitudeOffset(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y
            + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func longitudeOffset(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x
            + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}

extension CLLocationCoordinate2D {
    /// 把 GCJ-02 坐标换成 WGS-84。
    /// **现在没有调用方，接入前先读 `CoordinateTransform` 的说明**——在大陆把车端坐标
    /// 转成 WGS-84 再交给苹果的地图接口，落点会偏几百米。
    var wgs84FromGCJ02: CLLocationCoordinate2D {
        CoordinateTransform.wgs84(fromGCJ02: self)
    }
}
