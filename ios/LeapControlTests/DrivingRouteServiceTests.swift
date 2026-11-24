import CoreLocation
import Foundation
import Testing

@testable import LeapControl

/// 驾车距离的数据源与解析。
///
/// 这组测试守的不是「代码能跑」，是**两个一错就看不出来的地方**：
/// 高德把距离和耗时都写成字符串，以及多条候选方案不保证按距离排好。
/// 写错了界面上照样显示一个「约 1.3 公里 · 7 分钟」——像真的，但是假的。
struct DrivingRouteServiceTests {

    /// 真实形状的高德回包（`extensions=base`）：两条方案，**长的那条在前**。
    private func amapResponse(_ paths: String, status: String = "1") -> Data {
        Data("""
        {"status":"\(status)","info":"OK","infocode":"10000","count":"\(status == "1" ? 2 : 0)",
         "route":{"origin":"120.210009,30.247970","destination":"120.215527,30.246109",
         "paths":[\(paths)]}}
        """.utf8)
    }

    @Test("多条方案取最短的那条，不能拿回包里的第一条")
    func picksShortestPath() throws {
        // 苹果那边的老毛病就是「默认那条不一定最短」，高德这边同样不能想当然：
        // 回包里第一条 1324 米，第二条 892 米，显示的必须是 892。
        let data = amapResponse("""
        {"distance":"1324","duration":"426","steps":[]},
        {"distance":"892","duration":"318","steps":[]}
        """)
        let route = try #require(DrivingRouteService.parseAMap(data))
        #expect(route.distance == 892)
        #expect(route.duration == 318)
        #expect(route.source == .amap)
    }

    @Test("距离和耗时是高德回包里的字符串，要当真数字用")
    func parsesStringNumbers() throws {
        let data = amapResponse(#"{"distance":"634","duration":"240","steps":[]}"#)
        let route = try #require(DrivingRouteService.parseAMap(data))
        #expect(route.distance == 634)
        #expect(route.duration == 240)
    }

    @Test("缺耗时就只报距离，别把 0 秒当成「0 分钟」塞给界面")
    func missingDurationIsZeroNotCrash() throws {
        let data = amapResponse(#"{"distance":"700","steps":[]}"#)
        let route = try #require(DrivingRouteService.parseAMap(data))
        #expect(route.distance == 700)
        #expect(route.duration == 0)
    }

    @Test("高德报错（status=0）当作没有，交给苹果那条兜底")
    func failedStatusReturnsNil() {
        let data = amapResponse("", status: "0")
        #expect(DrivingRouteService.parseAMap(data) == nil)
    }

    @Test("距离为 0 或不是数字的方案直接丢掉")
    func rejectsNonPositiveDistance() {
        #expect(DrivingRouteService.parseAMap(amapResponse(#"{"distance":"0"}"#)) == nil)
        #expect(DrivingRouteService.parseAMap(amapResponse(#"{"distance":"--"}"#)) == nil)
        #expect(DrivingRouteService.parseAMap(Data("not json".utf8)) == nil)
    }

    @Test("请求地址：经度在前、坐标原样、不带任何换算")
    func amapURLFormat() throws {
        // 车端 GCJ-02 坐标原样进 URL。这里多转一次就是全体偏几百米，
        // 那个坑这个仓库已经踩过两次（见 CoordinateTransform）。
        let origin = CLLocationCoordinate2D(latitude: 30.246109, longitude: 120.215527)
        let destination = CLLocationCoordinate2D(latitude: 30.247970, longitude: 120.210009)
        let url = try #require(DrivingRouteService.amapURL(
            from: origin, to: destination, key: "  abc123  "
        ))
        #expect(url.host == "restapi.amap.com")
        #expect(url.path == "/v3/direction/driving")

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("origin") == "120.215527,30.246109")
        #expect(value("destination") == "120.210009,30.24797")
        // 首尾空白要去掉，否则高德会回 INVALID_USER_KEY。
        #expect(value("key") == "abc123")
        // 只要距离和时长，不要折线点。
        #expect(value("extensions") == "base")
    }

    @Test("没配 key 就不发请求，直接走苹果")
    func emptyKeySkipsAMap() {
        let point = CLLocationCoordinate2D(latitude: 30.2, longitude: 120.2)
        #expect(DrivingRouteService.amapURL(from: point, to: point, key: "") == nil)
        #expect(DrivingRouteService.amapURL(from: point, to: point, key: "   ") == nil)
    }
}
