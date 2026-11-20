import CoreLocation
import Foundation

/// GCJ-02 ↔ WGS-84 换算。**目前全端都没有接线，接回去之前先读完这段。**
///
/// **在中国大陆不需要转，转了就是错的。**车端上报的是 GCJ-02（国测局／「火星坐标」），
/// 而在大陆：苹果地图的底图是高德的 GCJ-02，`MKMapSnapshotter`／反地理编码同一套口径；
/// `CLLocationManager` 返回的坐标也已经由系统加过偏，同样是 GCJ-02。所以车端坐标
/// 原样喂给 MapKit、原样和定位算距离，都是对的；转成 WGS-84 反而会把点往西挪
/// 400~500 米（南方城市偏西北，北方偏西南）。跳高德（`dev=0`）／百度（`coord_type=gcj02`）／
/// 腾讯（`tocoord`）要的也是 GCJ-02。
///
/// **这个坑踩过一次，代价是所有用户，别再踩第二次：**2026-08-18 有一个用户报车辆位置偏，
/// 当时按「MapKit 入参一律 WGS-84、它自己纠偏到 GCJ-02 底图」这条通行说法接上了转换
/// （提交 `2364c5b`），当天 14:45 打包发出去，第二天**所有**用户都报偏——而在那之前
/// 只有那一个人报。回归的时间点和转换上线的时间点严丝合缝，转换随即回滚。
///
/// 当时用来支撑那条说法的观察是「同一张地图上 `UserAnnotation` 蓝点一直准」。观察没错，
/// 推论反了：蓝点准说明 CoreLocation 的输出和 MapKit 的底图在**同一侧**，而在大陆那一侧
/// 是 GCJ-02，不是 WGS-84。跨端也对得上——安卓（高德 SDK）、鸿蒙（华为 Petal）原生吃
/// GCJ-02，坐标都原样传，从没人反馈过偏。
///
/// **那什么时候才用得上它？**只有当拿到的坐标确实是 WGS-84 时（比如接入外部 GPS 设备、
/// 或者哪天车端换了口径并**实测**确认）。判据必须是实测：同一坐标在苹果地图和高德上落点
/// 是否重合，不能靠推理。个别用户位置不准优先查别的原因——地库／高楼下的车端 GPS 漂移、
/// 熄火时最后一帧位置——那些症状是**因人因时而异**的，而坐标系错误一定是**所有人、
/// 固定方向、固定量级**。
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
    /// 反向迭代要用它，所以这条也留着；单独调用的场合目前没有。
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
