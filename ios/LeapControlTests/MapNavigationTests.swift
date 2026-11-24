import CoreLocation
import Testing

@testable import LeapControl

/// 「导航到车辆」跳第三方地图时的坐标系口径。
///
/// 传进去的是 GCJ-02（`VehicleState.shareableCoordinate` 的出口，判据见 `AvailableMapApp.url(for:name:)` 的注释）。四家声明
/// 坐标系的方式各不相同，写错了**照样编译、照样能跳过去**，只是落点偏出几百米——
/// 而这件事只有站在车边打开导航才会发现。所以逐个钉死在这儿。
///
/// 曾经把百度那个参数写成 `coord_type=wgs84`：百度会在已经是 GCJ-02 的坐标上再叠
/// 一次纠偏。同一段代码里高德写的却是 `dev=0`（= 我给的是 GCJ-02），两者自相矛盾。
@Suite("地图导航坐标系")
struct MapNavigationTests {

    /// 杭州滨江，和 `VehicleSnapshot.placeholder` 用的是同一个点。
    private let coordinate = CLLocationCoordinate2D(latitude: 30.18682, longitude: 120.19551)

    private func navigationURL(_ app: AvailableMapApp) -> String? {
        app.url(for: coordinate, name: "我的车")?.absoluteString
    }

    @Test("高德声明 dev=0，即「给的是高德坐标」而不是 GPS 原始坐标")
    func amapDeclaresGCJ02() throws {
        let mapURL = try #require(navigationURL(.amap))
        #expect(mapURL.contains("dev=0"))
        #expect(!mapURL.contains("dev=1"))
        #expect(mapURL.contains("dlat=30.18682"))
        #expect(mapURL.contains("dlon=120.19551"))
    }

    /// 百度内部用 BD-09，必须靠 `coord_type` 告诉它输入是什么。
    @Test("百度声明 coord_type=gcj02，不是 wgs84")
    func baiduDeclaresGCJ02() throws {
        let mapURL = try #require(navigationURL(.baidu))
        #expect(mapURL.contains("coord_type=gcj02"))
        #expect(!mapURL.contains("wgs84"), "填 wgs84 会让百度在 GCJ-02 上再纠偏一次，落点偏几百米")
        #expect(mapURL.contains("latlng:30.18682,120.19551"))
        #expect(mapURL.contains("mode=driving"))
    }

    /// 腾讯默认按 GCJ-02 收，不需要额外参数——但坐标本身得原样传过去。
    @Test("腾讯直传坐标，按驾车规划")
    func tencentPassesCoordinateThrough() throws {
        let mapURL = try #require(navigationURL(.tencent))
        #expect(mapURL.contains("tocoord=30.18682,120.19551"))
        #expect(mapURL.contains("type=drive"))
    }

    /// 苹果地图不走 URL，由 `MKMapItem` 直接打开，所以这里必须是 nil——
    /// 真返回了一个 `maps://` 出来，调用方那条 `app != .apple` 的分支就会把它当外部
    /// App 跳走，反而绕开了 iOS 26 那套新的 `MKMapItem` 构造。
    @Test("苹果地图不返回 URL")
    func appleHasNoURL() {
        #expect(navigationURL(.apple) == nil)
    }

    /// 车名带空格时不能把 URL 拆坏——车主起的名字里有空格很常见。
    ///
    /// **已知局限，这里不假装它不存在：**编码用的是 `.urlQueryAllowed`，而这个字符集
    /// 本来就允许 `&` 和 `=`（它们是 query 的分隔符）。所以名字里真有 `&` 的话，
    /// 后面的部分会被地图 App 当成另一个参数。要修得换一个更严的字符集，那会动到
    /// 三家的 URL，不顺手在这儿做。
    @Test("车名里的空格做过百分号编码")
    func vehicleNameIsPercentEncoded() throws {
        let url = try #require(
            AvailableMapApp.amap.url(for: coordinate, name: "老王 的车")?.absoluteString
        )
        #expect(!url.contains("老王 的车"))
        #expect(url.contains("%20"))
    }
}
