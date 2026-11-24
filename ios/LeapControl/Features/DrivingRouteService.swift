import CoreLocation
import Foundation
import MapKit

/// 一段驾车路线：距离（米）+ 预计耗时（秒），以及**这个数是问谁要的**。
///
/// 带上来源不是为了显示，是为了查问题。同样两个点，高德回 0.9 公里、苹果回 1.3 公里，
/// 这种差异只有把来源记进日志才说得清；不然下次再有人报「距离不对」，还是只能靠猜。
struct DrivingRoute: Equatable, Sendable {
    let distance: CLLocationDistance
    let duration: TimeInterval
    let source: Source

    enum Source: String, Sendable {
        case amap
        case apple

        var label: String {
            switch self {
            case .amap: "高德"
            case .apple: "苹果"
            }
        }
    }
}

/// 驾车距离问谁要。
///
/// **默认问高德，不是苹果。** 三端本来各问各的：安卓走高德 SDK（`RouteSearchV2`）、
/// 鸿蒙走华为 Petal（`navi.getDrivingMatrix`），只有 iOS 用 `MKDirections`。
/// 坐标口径统一之后（见 `CoordinateTransform`），剩下的差异全在「谁来算这条路」上：
/// 苹果在大陆的路线引擎面对老城路网会给出更长的一条——绕开小路、多一个掉头、从主路
/// 而不是门前那条街起步，同一对起终点比高德多出几百米很常见。表现就是
/// 「车标已经落在车位上了，直线距离也对，可驾车距离还是偏大」，那不是坐标系问题。
///
/// 高德这条走 **Web 服务**（`restapi.amap.com`），不引 SDK：这里只要一个距离数字，
/// 为它拖几十兆的 SDK 进来不划算。key 从 Info.plist 的 `AMapWebKey` 读；
/// **空着就整个跳过、直接用苹果那套**——没配也能跑，只是不如高德准。
///
/// 高德 Web 服务 key 在 https://console.amap.com 申请（个人开发者免费，需实名），
/// 平台选「Web服务」。写进包里的办法见 `scripts/configure-signing.py --amap-key`。
enum DrivingRouteService {

    /// Info.plist 里的高德 Web 服务 key。空串表示没配。
    static var amapWebKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AMapWebKey") as? String
        return (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有没有可靠的数据源。**界面拿这个决定要不要显示「驾车距离」这一格。**
    ///
    /// 没配 key 时干脆不显示：苹果在市区老路里给的数常常偏大，摆一个自己都不信的
    /// 数字上去，比不摆更糟——车主会拿它跟高德比，然后开始怀疑是不是定位又坏了。
    /// 真要开过去，旁边的「导航到车辆」点一下就有准确路线和耗时。
    static var isConfigured: Bool { !amapWebKey.isEmpty }

    /// 取驾车路线：高德优先（和安卓端同一套数据），拿不到再退苹果。
    ///
    /// 两步都失败才返回 nil，界面据此显示「暂不可用」——直线距离是本地算的，
    /// 不受影响，照常显示。
    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> DrivingRoute? {
        if !amapWebKey.isEmpty, let route = await amapRoute(from: origin, to: destination) {
            return route
        }
        return await appleRoute(from: origin, to: destination)
    }

    // MARK: - 高德

    private static func amapRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> DrivingRoute? {
        guard let url = amapURL(from: origin, to: destination, key: amapWebKey) else { return nil }
        var request = URLRequest(url: url)
        // 位置页是个要立刻出数的界面，卡住比没有更难看。超时就退回苹果那条。
        //
        // 8 秒而不是 5 秒：手机上开着代理、或者 4G 信号在切换时，5 秒很容易不够，
        // 一超时就静默退回苹果——而苹果在这个区域给的距离比高德大一截，
        // 表现为「明明装了 key，数还是老样子」，从界面上根本看不出差别。
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let route = parseAMap(data) {
                BLEDiagnostics.record(
                    "route",
                    "高德 http=\(status) \(Int(route.distance.rounded()))m/\(Int(route.duration))s"
                )
                return route
            }
            // 走到这说明请求通了但回包不是「成功」：key 错、配额用尽、开了数字签名，
            // 高德会在 info/infocode 里说清楚。不记下来就只能靠猜。
            BLEDiagnostics.record("route", "高德无可用路线 http=\(status) \(failureSummary(data))")
            return nil
        } catch {
            BLEDiagnostics.record("route", "高德请求失败 \(BLEDiagnostics.error(error))")
            return nil
        }
    }

    /// 高德失败回包里到底说了什么。只为诊断，不参与业务判断。
    static func failureSummary(_ data: Data) -> String {
        struct Failure: Decodable {
            let status: String?
            let info: String?
            let infocode: String?
        }
        guard let f = try? JSONDecoder().decode(Failure.self, from: data) else {
            return "回包无法解析（\(data.count) 字节）"
        }
        return "status=\(f.status ?? "-") info=\(f.info ?? "-") code=\(f.infocode ?? "-")"
    }

    /// 高德驾车路线的请求地址。
    ///
    /// **入参是 GCJ-02**（`VehicleState.shareableCoordinate` 的出口），高德 Web 服务收的
    /// 也是 GCJ-02，所以这里原样传，一个字节都不要换算。转一次就偏几百米——
    /// 这个坑在这个仓库里已经踩过两次，见 `CoordinateTransform`。
    static func amapURL(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        key: String
    ) -> URL? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://restapi.amap.com/v3/direction/driving")
        components?.queryItems = [
            // 高德要的是「经度,纬度」，别写成纬在前。
            URLQueryItem(name: "origin", value: "\(origin.longitude),\(origin.latitude)"),
            URLQueryItem(name: "destination", value: "\(destination.longitude),\(destination.latitude)"),
            // 0 = 速度优先，和高德 App 默认推荐的那条一致，安卓端用的也是这个策略。
            URLQueryItem(name: "strategy", value: "0"),
            // 只要距离和时长，不要每条路的折线点，回包小一个数量级。
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "key", value: trimmed)
        ]
        return components?.url
    }

    /// 解析高德驾车路线的回包，取最短的那条方案。
    ///
    /// 单独拆出来是为了能测。两个容易写错、错了又「看着像真的」的地方：
    /// 距离和耗时在高德回包里都是**字符串**（`"distance": "1234"`），
    /// 以及多条方案**不保证按距离排好**，必须自己比。
    static func parseAMap(_ data: Data) -> DrivingRoute? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                struct Path: Decodable {
                    let distance: String?
                    let duration: String?
                }
                let paths: [Path]?
            }
            let status: String?
            let route: Payload?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              // "1" 才是成功；失败时 status 是 "0"，route 缺失，info 里有原因。
              envelope.status == "1",
              let paths = envelope.route?.paths, !paths.isEmpty
        else { return nil }

        let candidates: [DrivingRoute] = paths.compactMap { path in
            guard let text = path.distance, let distance = Double(text), distance > 0 else {
                return nil
            }
            // 没给耗时就当 0，界面上那一截「· N 分钟」会省掉，比整条路线丢掉好。
            let seconds = path.duration.flatMap { Double($0) } ?? 0
            return DrivingRoute(distance: distance, duration: seconds, source: .amap)
        }
        return candidates.min { $0.distance < $1.distance }
    }

    // MARK: - 苹果

    private static func appleRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> DrivingRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        // 苹果默认只回一条，而且不保证是最短的那条。把所有候选都要回来、自己取最短，
        // 这一步不多花时间，但能少掉一截「明明有近路却给了绕行」的冤枉距离。
        request.requestsAlternateRoutes = true
        guard let response = try? await MKDirections(request: request).calculate(),
              let best = response.routes.min(by: { $0.distance < $1.distance }),
              best.distance > 0
        else { return nil }
        return DrivingRoute(
            distance: best.distance,
            duration: best.expectedTravelTime,
            source: .apple
        )
    }
}
