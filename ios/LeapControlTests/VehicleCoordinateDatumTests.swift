import CoreLocation
import Foundation
import Testing

@testable import LeapControl

/// 车辆坐标的**坐标系口径**。
///
/// 这一组测试锁的是 1.1 版那次全体偏移：车端同帧上报三组经纬度，`2`/`3` 是车机已经转好的
/// GCJ-02，`3724`/`3725`、`2190`/`2191` 是 GPS 原始 WGS-84。1.1 把后者排到了最前面，
/// 于是 WGS-84 被当 GCJ-02 直接画在 GCJ-02 的底图上，每台车都偏 500 多米。
///
/// 断言里用的就是那份实测帧（`CabinComfortTests.c16`，经纬度已换成示例值）：
///   `2/3`         = 120.215527 / 30.246109
///   `3724/3725`   = 120.210009 / 30.24797
///   `2190/2191`   = 120.210028 / 30.247968
///
/// 判据本身就是这组数：`3724/3725` 与 `2190/2191` 差不到 2 米（同一路 GPS 的两份拷贝），
/// 与 `2/3` 差 569 米；而 569 米这个方向、这个量级正好是本地的 WGS-84→GCJ-02 偏移量。
@Suite("车辆坐标口径")
struct VehicleCoordinateDatumTests {

    private func state(_ pairs: [String: String], schema: SignalSchema? = nil) -> VehicleState {
        var state = VehicleState()
        state.signalMap = pairs
        state.schema = schema ?? SignalSchema.detect(pairs)
        return state
    }

    private func distance(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    /// 三组同时在场的完整帧。
    private let frame: [String: String] = [
        "1": "1786972478598",
        "100003": "90.6",
        "2": "120.215527", "3": "30.246109",
        "2190": "120.210028", "2191": "30.247968",
        "3724": "120.210009", "3725": "30.24797"
    ]

    // MARK: - 分组表本身

    @Test("数字口径把三组经纬度按坐标系分开声明")
    func numericDeclaresGroupsByDatum() {
        let groups = SignalSchema.numeric.coordinateGroups
        #expect(groups.count == 3)
        // 第一组是 GCJ-02，可以原样上图；其余两组是 WGS-84，必须换算。
        #expect(groups[0].longitudeKey == "2")
        #expect(groups[0].latitudeKey == "3")
        #expect(groups[0].datum == .gcj02)
        #expect(groups.dropFirst().allSatisfy { $0.datum == .wgs84 })
        #expect(groups.map(\.longitudeKey) == ["2", "3724", "2190"])
        // WGS-84 那两组的 lat/lon 不能配错：经纬度成对，配错会飞到几百公里外。
        #expect(groups[1].longitudeKey == "3724")
        #expect(groups[1].latitudeKey == "3725")
        #expect(groups[2].longitudeKey == "2190")
        #expect(groups[2].latitudeKey == "2191")
    }

    @Test("语义名口径（S01/T03）只有一组，按 GCJ-02 处理")
    func legacyDeclaresSingleGroup() {
        let groups = SignalSchema.legacy.coordinateGroups
        #expect(groups.count == 1)
        #expect(groups[0].longitudeKey == "longitude")
        #expect(groups[0].latitudeKey == "latitude")
        #expect(groups[0].datum == .gcj02)
        // T03 那份派生表必须跟着 legacy 走，不能掉成空表。
        #expect(SignalSchema.detect(["soc": "80"], carType: "T03").resolvedCoordinateGroups.count == 1)
    }

    @Test("没有分组表的手工 schema 退回「不转」，不会平白把坐标推偏")
    func handBuiltSchemaFallsBackToPassThrough() {
        let schema = SignalSchema(id: "test", keys: [
            .longitude: ["lon"], .latitude: ["lat"]
        ])
        let groups = schema.resolvedCoordinateGroups
        #expect(groups.count == 1)
        #expect(groups[0].datum == .gcj02)
    }

    @Test("叠加标定结果不会把坐标分组弄丢")
    func mergingKeepsGroups() {
        let merged = SignalSchema.numeric.merging([.acSetting: "2183"])
        #expect(merged.coordinateGroups == SignalSchema.numeric.coordinateGroups)
    }

    // MARK: - 取值

    @Test("三组同时在场：取 2/3，原样返回，不做任何换算")
    func prefersGCJ02PairUntouched() throws {
        let state = state(frame)
        let coordinate = try #require(state.shareableCoordinate)
        #expect(coordinate.latitude == 30.246109)
        #expect(coordinate.longitude == 120.215527)
        #expect(state.coordinateReading?.datum == .gcj02)
    }

    @Test("只报 3724/3725：按 WGS-84 转一次，落点与车机给的 GCJ-02 相差不到 150 米")
    func convertsWGS84RawPair() throws {
        var pairs = frame
        pairs["2"] = nil
        pairs["3"] = nil
        let converted = try #require(state(pairs).shareableCoordinate)

        // 不转的落点（即 1.1 的错误行为）离车机那份 GCJ-02 有 569 米。
        let raw = CLLocationCoordinate2D(latitude: 30.24797, longitude: 120.210009)
        let carGCJ = CLLocationCoordinate2D(latitude: 30.246109, longitude: 120.215527)
        #expect(distance(raw, carGCJ) > 500)

        // 转完剩 110 米上下，差的这点是车机自己做过的道路吸附。
        #expect(distance(converted, carGCJ) < 150)
        // 换算方向不能反：GCJ-02 在同纬度上恒在 WGS-84 东侧，转完经度必须变大。
        #expect(converted.longitude > raw.longitude)
    }

    @Test("只报 2190/2191：同样按 WGS-84 处理")
    func convertsLegacyWGS84Pair() throws {
        var pairs = frame
        for key in ["2", "3", "3724", "3725"] { pairs[key] = nil }
        let coordinate = try #require(state(pairs).shareableCoordinate)
        #expect(state(pairs).coordinateReading?.datum == .wgs84)
        #expect(distance(coordinate, CLLocationCoordinate2D(latitude: 30.246109, longitude: 120.215527)) < 150)
    }

    @Test("经度纬度必须来自同一组，不能跨组拼")
    func neverMixesPairs() {
        // 只有 `2` 和 `3725`：凑不出一组，宁可没有位置也不要拼一个假点。
        let partial = state(["1": "1786972478598", "2": "120.215527", "3725": "30.24797"])
        #expect(partial.shareableCoordinate == nil)
        #expect(partial.coordinateReading == nil)
    }

    @Test("隐私模式下不给坐标")
    func privacyBlocksCoordinate() {
        let pairs = ["soc": "76", "latitude": "30.259255", "longitude": "120.185362", "privacyGPS": "false"]
        #expect(state(pairs).privacyGPSAllowed == false)
        #expect(state(pairs).shareableCoordinate == nil)
        // 解析层不替车端撒谎：原始值还在，只是不对外给坐标。
        #expect(state(pairs).latitude == 30.259255)
    }

    @Test("语义名口径的坐标原样返回")
    func legacyPassesThrough() throws {
        let coordinate = try #require(state([
            "soc": "76", "latitude": "30.259255", "longitude": "120.185362"
        ]).shareableCoordinate)
        #expect(coordinate.latitude == 30.259255)
        #expect(coordinate.longitude == 120.185362)
    }

    @Test("非法坐标挡掉，不把一个假点交给地图")
    func invalidCoordinatesRejected() {
        // 量程越界（经度 ±180、纬度 ±90）直接判非法。
        #expect(state(["1": "1", "2": "200", "3": "30.2"]).shareableCoordinate == nil)
        #expect(state(["1": "1", "2": "120.1", "3": "95"]).shareableCoordinate == nil)
        // 解不出数字就当没报：宁可显示「暂无车辆位置」，也不能落一个点上去。
        #expect(state(["1": "1", "2": "abc", "3": "30.2"]).shareableCoordinate == nil)
        #expect(state(["1": "1", "2": "", "3": "30.2"]).shareableCoordinate == nil)
    }
}
