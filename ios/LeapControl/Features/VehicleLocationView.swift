import MapKit
import SwiftUI
import CoreLocation
import Combine
import UIKit

struct VehicleLocationView: View {
    @Environment(VehicleStore.self) private var store
    @StateObject private var userLocation = UserLocationProvider()
    @State private var showingMapChoices = false
    @State private var drivingRoute: DrivingRoute?
    @State private var drivingRouteUnavailable = false
    @State private var parkingPhoto: ParkingPhoto?
    @State private var parkingImage: UIImage?
    @State private var isLoadingParkingPhoto = false
    @State private var isShowingParkingPhoto = false

    /// 已经是 GCJ-02（`VehicleState.shareableCoordinate` 转过的那一个）。这一页所有用到
    /// 坐标的地方——地图、两个距离、跳各家地图——都用它，**不许再转**（见 `CoordinateTransform`）。
    private var coordinate: CLLocationCoordinate2D? { store.coordinate }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let coordinate {
                VehicleMap(coordinate: coordinate,
                           vehicleName: store.vehicleName,
                           userCoordinate: userLocation.location?.coordinate)
            } else {
                LeapBackground(tint: LeapStyle.cool)
                ContentUnavailableView {
                    Label("暂无车辆位置", systemImage: "location.slash")
                } description: {
                    Text(store.state?.privacyGPSAllowed == false
                         ? "车辆已开启位置隐私模式，App 无法获取坐标。"
                         : "车况里还没有上报经纬度，稍后再试。")
                }
            }

            infoCard
        }
        .navigationTitle("车辆位置")
        .navigationBarTitleDisplayMode(.inline)
        // 地图不是滚动视图，导航栏拿不到滚动边缘效果，需要显式给背景，否则标题压在地图上看不清。
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .task {
            userLocation.start()
        }
        .task(id: MetricsKey(user: userLocation.location, vehicle: coordinate)) {
            // 没配高德 key 就连请求都不发：那一格本来就不显示。
            guard DrivingRouteService.isConfigured else { return }
            await updateDrivingMetrics(vehicle: coordinate)
        }
        .task(id: coordinate?.latitude) {
            guard coordinate != nil, store.locationName == nil else { return }
            await store.resolveLocationName()
        }
        // 换车就得重拉：照片是按当前 VIN 取的，不换 id 会把上一台车停在哪的画面留在卡里。
        .task(id: store.session.selectedVin) { await loadParkingPhoto() }
        .fullScreenCover(isPresented: $isShowingParkingPhoto) {
            if let parkingImage {
                ParkingPhotoViewer(image: parkingImage, caption: parkingPhoto?.displayUploadTime)
            }
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 左文右图：地址、时间、两个距离在左边竖着排，右边一张竖着的驻车照片。
            // 照片原来是整卡宽、高 108 的一条，`scaledToFill` + `clipped` 把竖着拍的
            // 照片从中间横切一刀——车停在几号位、旁边是什么全被切掉了，只剩中间一条。
            // 竖图配竖图，占的宽度还更小。
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.locationName ?? "正在解析位置")
                        .font(.headline)
                        .lineLimit(2)
                    if let updated = store.lastUpdated {
                        Text("更新于 \(updated, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 16) {
                        distanceMetric(title: "直线距离", value: straightDistanceText)
                        // 没配高德 key 就整格不出现：这一格以前问的是苹果，市区老路里
                        // 给出的距离常常偏大，和车标位置对不上，反而让人怀疑定位。
                        // 要开过去点下面的「导航到车辆」就行，那条路线是准的。
                        if DrivingRouteService.isConfigured {
                            distanceMetric(title: drivingMetricTitle, value: drivingDistanceText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                parkingPhotoThumb
            }
            // 这一句不能少。上面那个 Spacer 只想把两个距离压到左栏底部、跟照片底边
            // 齐平，但整张卡是叠在全屏地图上的（外层 ZStack），高度没有上界——Spacer
            // 会一路吃到屏幕底，卡片撑满整个地图，中间空出一大片。
            // 固定垂直方向取理想高度后，这一行的高度就是 max(左栏文字, 照片 104)，
            // Spacer 只在照片更高时吃掉那点差额。
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    showingMapChoices = true
                } label: {
                    Label("导航到车辆", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .leapGlassButton(prominent: true)
                .tint(LeapStyle.cool)
                .disabled(coordinate == nil)
                // iOS 26 起确认弹窗会锚定在修饰符附着的视图上弹出。
                // 挂在最外层 ZStack 上它会锚到整屏，必须挂在触发它的按钮上。
                .confirmationDialog("选择地图", isPresented: $showingMapChoices, titleVisibility: .visible) {
                    ForEach(AvailableMapApp.allCases.filter { $0.isAvailable }, id: \.self) { app in
                        Button(app.title) { openInMaps(app) }
                    }
                    Button("取消", role: .cancel) {}
                }

                Button {
                    Task { await store.refresh(showSpinner: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 46)
                        .padding(.vertical, 13)
                }
                .leapGlassButton()
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .leapGlass(.regular, in: .rect(cornerRadius: 28))
        .padding(14)
    }

    // MARK: - 驻车照片

    /// 位置卡右边那张驻车照片：车停在哪、当时长什么样，一眼看完。
    ///
    /// 竖着放、按原比例装进 78×104 的框里，不裁。车主拍驻车位置基本都是竖着拍的，
    /// 横切一刀就只剩中间一条，看不出停在哪个位置。上传时间不往这么小的图上压，
    /// 挪到点开的大图里去说。
    ///
    /// 没解锁、演示模式、这台车没照片，整块都不出现——位置卡对这些人保持原样，
    /// 不摆空占位也不摆上锁提示，那些都在功能中心那页说过了。
    @ViewBuilder
    private var parkingPhotoThumb: some View {
        if let parkingImage {
            Button {
                isShowingParkingPhoto = true
            } label: {
                Image(uiImage: parkingImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(LeapStyle.glassEdge, lineWidth: 0.8)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .padding(5)
                            .background(.ultraThinMaterial, in: .circle)
                            .padding(5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("驻车照片")
            .accessibilityHint("点两下查看大图")
        } else if isLoadingParkingPhoto {
            // 拉取期间先占住这块，出图时左边那列的宽度不会跳一下。
            ProgressView()
                .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                .leapGlass(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private static let thumbWidth: CGFloat = 78
    private static let thumbHeight: CGFloat = 104

    /// 拉最近一张驻车照片。失败、没照片都只是不显示，不打扰——
    /// 这里是位置页的附加信息，读不到就当没有，报错留给功能中心那页说。
    private func loadParkingPhoto() async {
        guard !store.isDemo else {
            parkingPhoto = nil
            parkingImage = nil
            return
        }
        isLoadingParkingPhoto = true
        defer { isLoadingParkingPhoto = false }
        do {
            let (photo, data) = try await store.loadParkingPhoto()
            parkingPhoto = photo
            parkingImage = data.flatMap(UIImage.init(data:))
        } catch {
            parkingPhoto = nil
            parkingImage = nil
        }
    }

    private var straightDistanceText: String {
        // 两边都是 GCJ-02：在中国大陆 `CLLocationManager` 返回的就是加过偏的 GCJ-02，
        // 车端坐标也已经归一过。谁被单独转一次，人站在车边上都会显示几百米。
        guard let vehicle = coordinate, let user = userLocation.location else { return "定位中" }
        return formatDistance(CLLocation(latitude: vehicle.latitude, longitude: vehicle.longitude)
            .distance(from: user))
    }

    /// 「驾车距离」这一格的小标题，把**数据是谁给的**写在上面。
    ///
    /// 不是为了炫技，是因为「数不对」和「数是从另一家要的」在界面上长得一模一样：
    /// 高德回 933 米、苹果回 1.3 公里，同一个格子同一个位置，只是数字不同。
    /// 没有这个标注，就只能靠猜是 key 没生效、网络失败，还是这个区域本来就该这么远。
    ///
    /// 有来源就一直显示：车主知道这一格是高德给的还是苹果给的，本身就值这个像素。
    private var drivingMetricTitle: String {
        guard let route = drivingRoute else { return routeMode.title }
        return "\(routeMode.title) · \(route.source.label)"
    }

    /// 这一格该按步行还是按驾车算。
    ///
    /// 找自己的车，人是走过去的，所以近距离一律按步行——车停进巷子、单行道里侧时，
    /// 驾车会绕出一倍的距离（实测同一对点步行 363 米、驾车 1486 米），那不是用户要的答案。
    /// 判据只用直线距离，不依赖任何网络结果，所以这个值在算路之前就已经定了。
    private var routeMode: TravelMode {
        guard let user = userLocation.location, let vehicle = coordinate else { return .walking }
        let straight = user.distance(
            from: CLLocation(latitude: vehicle.latitude, longitude: vehicle.longitude)
        )
        return TravelMode.preferred(forStraightDistance: straight)
    }

    private var drivingDistanceText: String {
        guard let route = drivingRoute else {
            if userLocation.location == nil { return "定位中" }
            return drivingRouteUnavailable ? "暂不可用" : "计算中"
        }
        // 耗时是「算出来的估计」，不是倒计时，取整到分钟就够；没给耗时（0）就只报距离，
        // 别拿 0 分钟或凑出来的 1 分钟去填。不到一分钟的短途也归到 1 分钟，写 0 更像出错。
        guard route.duration > 0 else { return formatDistance(route.distance) }
        let minutes = max(1, Int((route.duration / 60).rounded()))
        return "\(formatDistance(route.distance)) · \(minutes) 分钟"
    }

    private func distanceMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? "约 \(Int(meters.rounded())) 米" : String(format: "约 %.1f 公里", meters / 1000)
    }

    /// 取一次驾车路线。
    ///
    /// 问谁要、为什么不再只用苹果那套，见 `DrivingRouteService`。直线距离是本地算的，
    /// 不依赖任何服务，这条路走不通时它照常显示。
    private func updateDrivingMetrics(vehicle: CLLocationCoordinate2D?) async {
        guard let vehicle, let user = userLocation.location else {
            drivingRoute = nil
            drivingRouteUnavailable = false
            return
        }
        let mode = TravelMode.preferred(
            forStraightDistance: user.distance(
                from: CLLocation(latitude: vehicle.latitude, longitude: vehicle.longitude)
            )
        )
        let route = await DrivingRouteService.route(from: user.coordinate, to: vehicle, mode: mode)
        // 人挪了或车报了新坐标时，`.task(id:)` 会把上一次取消掉。被取消的那次回得晚，
        // 结果不能盖掉新的——否则界面上会留在旧位置上，看着像「距离不跟着变」。
        guard !Task.isCancelled else { return }
        drivingRoute = route
        drivingRouteUnavailable = route == nil
        if let route {
            BLEDiagnostics.record(
                "route",
                "\(mode.title) \(Int(route.distance.rounded()))m/\(Int(route.duration))s 来源=\(route.source.label)"
            )
        } else {
            BLEDiagnostics.record("route", "路线算不出来（高德/苹果都没给） mode=\(mode)")
        }
    }

    /// 四家收的都是 GCJ-02，坐标只有一份：国内三家按各自参数声明（见 `AvailableMapApp.url`），
    /// 苹果地图在大陆用的也是 GCJ-02 底图，同样原样给。
    private func openInMaps(_ app: AvailableMapApp) {
        guard let coordinate else { return }
        if app != .apple, let url = app.url(for: coordinate, name: store.vehicleName) {
            UIApplication.shared.open(url)
            return
        }
        // iOS 26 起 MKPlacemark 那条路被弃用，换成了直接拿 CLLocation 构造。
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            item = MKMapItem(location: location, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = store.vehicleName
        // 车通常停在步行可达的地方，直接给步行路线。
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

}

/// 驻车照片全屏查看。捏合放大看细节（停在几号车位、旁边是什么），松开手指回到贴边。
private struct ParkingPhotoViewer: View {
    let image: UIImage
    var caption: String?

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 手势进行中的增量，和已经定下来的 scale/offset 相乘或相加后才是最终值。
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private var currentScale: CGFloat { scale * pinch }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(currentScale)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            // 缩到 1 倍以下就弹回贴边，同时把平移一并归零，
                            // 否则松手后会停在一个既小又偏出屏幕的位置。
                            scale = max(1, min(4, scale * value.magnification))
                            if scale == 1 { offset = .zero }
                        }
                )
                .simultaneousGesture(
                    // 原尺寸下不接管拖动：那时没有可平移的余量，接管只会让下面的关闭手势失灵。
                    DragGesture()
                        .updating($drag) { value, state, _ in
                            guard scale > 1 else { return }
                            state = value.translation
                        }
                        .onEnded { value in
                            guard scale > 1 else { return }
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                        offset = .zero
                    }
                }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

private struct MetricsKey: Equatable {
    let userLatitude: Double?
    let userLongitude: Double?
    let vehicleLatitude: Double?
    let vehicleLongitude: Double?

    /// 坐标先量化到约 11 米再参与比较，**这一步是必须的**。
    ///
    /// 原来直接拿 `CLLocation.coordinate` 的原始 Double 比：人站在那儿不动，GPS 也会
    /// 每秒抖几十厘米，纬度经度每帧都是新值，于是这个 key 一直在变，`.task(id:)` 就
    /// 一直在重算——一秒能发好几次高德请求。个人开发者的 QPS 只有个位数，立刻被限流
    /// （`CUQPS_HAS_EXCEEDED_THE_LIMIT`），而失败是静默退回苹果的：界面上照样有数，
    /// 只是那个数是苹果的。表现出来就是「明明配了 key，距离还是老样子」，极难查。
    ///
    /// 4 位小数 ≈ 11 米。走 11 米才重算一次，这个精度对「到车还有多远」毫无损失。
    private static func quantize(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    init(user: CLLocation?, vehicle: CLLocationCoordinate2D?) {
        userLatitude = user.map { Self.quantize($0.coordinate.latitude) }
        userLongitude = user.map { Self.quantize($0.coordinate.longitude) }
        vehicleLatitude = vehicle.map { Self.quantize($0.latitude) }
        vehicleLongitude = vehicle.map { Self.quantize($0.longitude) }
    }
}

/// 「导航到车辆」能跳的地图。不设 `private`：`MapNavigationTests` 要逐个核对
/// URL 里的坐标系参数——那种写错了照样编译、只有到了车边才发现落点偏几百米的东西。
enum AvailableMapApp: String, CaseIterable, Identifiable {
    case apple, amap, baidu, tencent
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: "苹果地图"; case .amap: "高德地图"; case .baidu: "百度地图"; case .tencent: "腾讯地图" }
    }
    /// 装没装这个地图 App。`UIApplication.shared` 是 MainActor 隔离的，所以这条也得标上，
    /// 否则 Swift 6 的严格并发下这是个错误（现在只是警告）。调用点在 View body 里，
    /// 本来就在主线程上，标了不影响任何地方。
    @MainActor
    var isAvailable: Bool {
        guard self != .apple else { return true }
        guard let url = URL(string: scheme + "://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
    private var scheme: String {
        switch self { case .apple: "maps"; case .amap: "iosamap"; case .baidu: "baidumap"; case .tencent: "qqmap" }
    }
    /// 传进来的是 **GCJ-02**（国测局／「火星坐标」，`shareableCoordinate` 的出口），
    /// 三家的参数都按这个口径写，所以这里不许再转。苹果地图那条也一样，见
    /// `CoordinateTransform`。
    ///
    /// **每家声明坐标系的方式都不一样，这里逐个写死，别照抄别处的模板：**
    /// - 高德 `dev`：0 = 我给的是高德坐标（GCJ-02），1 = GPS 原始坐标（WGS-84）。
    /// - 百度 `coord_type`：百度自己内部用 BD-09，得靠这个参数告诉它输入是什么，
    ///   它再转一次。填 `wgs84` 会让它在 GCJ-02 上又叠一次纠偏，落点偏出几百米。
    /// - 腾讯 `tocoord`：默认就按 GCJ-02 收，不需要额外参数。
    func url(for coordinate: CLLocationCoordinate2D, name: String) -> URL? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        switch self {
        case .apple: return nil
        case .amap:
            return URL(string: "iosamap://path?dlat=\(coordinate.latitude)&dlon=\(coordinate.longitude)&dname=\(encodedName)&dev=0&t=0")
        case .baidu:
            return URL(string: "baidumap://map/direction?destination=name:\(encodedName)|latlng:\(coordinate.latitude),\(coordinate.longitude)&mode=driving&coord_type=gcj02")
        case .tencent:
            return URL(string: "qqmap://map/routeplan?type=drive&to=\(encodedName)&tocoord=\(coordinate.latitude),\(coordinate.longitude)")
        }
    }
}

@MainActor
private final class UserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 20
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }
}

/// 车辆位置地图。
///
/// 样式必须是平面 `.standard`。用 `.standard(elevation: .realistic)` 时，
/// 车停在没有 3D 数据覆盖的地方（国内只有大城市有）整屏就是一片空瓦片网格，
/// 只有网格线和版权字样，等多久都不出图，得用户自己捏合缩小到有数据的层级才行。
/// 首页那张缩略图一直是平面 `.standard`，在同样的位置从来没出过这毛病。
///
/// 相机也在 `init` 里就落到车辆所在的区域，不走 `.automatic` 再飞过去那一跳。
private struct VehicleMap: View {
    let coordinate: CLLocationCoordinate2D
    let vehicleName: String
    /// 手机自己在哪。没定位到就不摆「回到我的位置」那个钮——按下去没地方可去。
    let userCoordinate: CLLocationCoordinate2D?

    @State private var camera: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D, vehicleName: String, userCoordinate: CLLocationCoordinate2D?) {
        self.coordinate = coordinate
        self.vehicleName = vehicleName
        self.userCoordinate = userCoordinate
        _camera = State(initialValue: .region(Self.region(around: coordinate)))
    }

    var body: some View {
        Map(position: $camera) {
            Annotation(vehicleName, coordinate: coordinate) {
                VehicleMarker()
            }
            UserAnnotation()
        }
        .mapStyle(.standard)
        .ignoresSafeArea(edges: .top)
        // 「回到车辆」放导航栏，不放地图上的悬浮控件：地图 ignoresSafeArea 之后，
        // 无论是 .mapControls 还是自己写的 overlay，落点都不可靠——真机上会飘。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { camera = .region(Self.region(around: coordinate)) }
                } label: {
                    Image(systemName: "scope")
                }
                .accessibilityLabel("回到车辆")
            }
            if let userCoordinate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { camera = .region(Self.region(around: userCoordinate)) }
                    } label: {
                        Image(systemName: "location")
                    }
                    .accessibilityLabel("回到我的位置")
                }
            }
        }
        // 十秒一次的轮询里坐标没变就不动相机，免得把用户刚拖到的视野拽回去。
        .onChange(of: CoordinateKey(coordinate)) { _, new in
            withAnimation { camera = .region(Self.region(around: new.coordinate)) }
        }
    }

    private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )
    }
}

/// `CLLocationCoordinate2D` 不是 `Equatable`，`onChange` 需要一个能比较的包装。
private struct CoordinateKey: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct VehicleMarker: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LeapStyle.cool.opacity(0.22))
                .frame(width: 54, height: 54)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)

            Image(systemName: "car.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(LeapStyle.cool))
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: LeapStyle.cool.opacity(0.6), radius: 8)
        }
        .onAppear { pulse = true }
    }
}
