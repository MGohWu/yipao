import CoreLocation
import Testing

@testable import LeapControl

/// GCJ-02 ↔ WGS-84 换算的数学正确性。
///
/// **注意：`CoordinateTransform` 在生产代码里只有一个调用方**——`VehicleState.shareableCoordinate`，
/// 且只在「车只报了 `3724/3725` 或 `2190/2191` 这两组 WGS-84 原始坐标」时才转。`2/3` 本来就是
/// GCJ-02，原样上图（原委见 `CoordinateTransform` 头注释）。这组测试保的是「换算本身是对的」：
/// 它通过**不代表**该往渲染链路里加调用点，多转一次照样偏半公里。
@Suite("坐标系换算")
struct CoordinateTransformTests {

    /// 杭州滨江，和 `VehicleSnapshot.placeholder` 用的是同一个点（车端口径，GCJ-02）。
    private let hangzhou = CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551)

    private func distance(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    @Test("往返一次能回到原点")
    func roundTripIsLossless() {
        let wgs84 = CoordinateTransform.wgs84(fromGCJ02: hangzhou)
        let backToGCJ02 = CoordinateTransform.gcj02(fromWGS84: wgs84)
        // 迭代逼近，不要求逐位相等，但误差必须远小于「看得出来」的量级。
        #expect(distance(hangzhou, backToGCJ02) < 0.01)
    }

    /// 偏移量在大陆是几百米这个量级。太小说明换算没生效（等于没修），
    /// 太大说明算错了方向或者转反了。
    @Test("换算确实挪动了几百米")
    func offsetIsHundredsOfMeters() {
        let wgs84 = CoordinateTransform.wgs84(fromGCJ02: hangzhou)
        let moved = distance(hangzhou, wgs84)
        #expect(moved > 100, "偏移几乎为零，换算没生效")
        #expect(moved < 1000, "偏移过大，算法用错了")
    }

    /// 转反了同样是几百米量级，光看距离分不出来，所以这里钉方向。
    ///
    /// **只能钉经度：**经度偏移在大陆范围内恒为正（GCJ-02 比 WGS-84 偏东），反算回去必然往西收。
    /// 纬度偏移的符号是随纬度带变的——北京、哈尔滨为正，杭州、三亚为负——所以「整体往东北推」
    /// 那个流传的说法只对了一半，照它写断言会挂在杭州这个点上。
    @Test("GCJ-02 转回 WGS-84 时经度往西收", arguments: [
        CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551),  // 杭州
        CLLocationCoordinate2D(latitude: 39.9088, longitude: 116.3975),    // 北京
        CLLocationCoordinate2D(latitude: 45.8038, longitude: 126.5349),    // 哈尔滨
        CLLocationCoordinate2D(latitude: 18.2528, longitude: 109.5119)     // 三亚
    ])
    func longitudeShiftsWest(_ coordinate: CLLocationCoordinate2D) {
        let wgs84 = CoordinateTransform.wgs84(fromGCJ02: coordinate)
        #expect(wgs84.longitude < coordinate.longitude)
    }

    /// 上面几条都只验自洽（往返、量级、方向），系数整体抄错了照样能自洽。
    /// 这条拿一个独立算出来的定点钉住正向公式本身，改动系数会立刻在这儿露出来。
    @Test("正向换算对得上定点")
    func forwardMatchesKnownFixture() {
        let wgs84 = CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551)
        let gcj02 = CoordinateTransform.gcj02(fromWGS84: wgs84)
        #expect(abs(gcj02.latitude - 30.184411) < 0.000001)
        #expect(abs(gcj02.longitude - 120.200079) < 0.000001)
    }

    /// 境外 GCJ-02 和 WGS-84 本来就相等，硬转会把本来准的坐标推偏几百米。
    @Test("境外坐标原样返回", arguments: [
        CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),   // 东京
        CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),  // 旧金山
        CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)   // 悉尼
    ])
    func outsideChinaIsUntouched(_ coordinate: CLLocationCoordinate2D) {
        let converted = CoordinateTransform.wgs84(fromGCJ02: coordinate)
        #expect(converted.latitude == coordinate.latitude)
        #expect(converted.longitude == coordinate.longitude)
    }

    /// 换算是逐点算的，不是加一个常数偏移——南北两地的偏移量不该一样。
    @Test("偏移量随位置变化")
    func offsetVariesByLocation() {
        let harbin = CLLocationCoordinate2D(latitude: 45.8038, longitude: 126.5349)
        let sanya = CLLocationCoordinate2D(latitude: 18.2528, longitude: 109.5119)
        let northOffset = distance(harbin, CoordinateTransform.wgs84(fromGCJ02: harbin))
        let southOffset = distance(sanya, CoordinateTransform.wgs84(fromGCJ02: sanya))
        #expect(abs(northOffset - southOffset) > 1)
    }

    /// 便利属性和底层函数必须是同一条路径——用错了不会报错，只会偏。
    @Test("wgs84FromGCJ02 与 CoordinateTransform 一致")
    func convenienceMatchesTransform() {
        let viaProperty = hangzhou.wgs84FromGCJ02
        let viaTransform = CoordinateTransform.wgs84(fromGCJ02: hangzhou)
        #expect(viaProperty.latitude == viaTransform.latitude)
        #expect(viaProperty.longitude == viaTransform.longitude)
    }
}
