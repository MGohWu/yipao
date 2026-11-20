import SwiftUI
import WebKit

/// 官方那套 3D 车模型，跑在 WKWebView 里。
///
/// 渲染器是零跑自己的 WebGL 包（Three.js + FBX），我们只做三件事：
/// 把解压好的资源喂给它、按车型参数调 `newInit` 起模型、把车况变化用
/// `window.controller` 推进去（开门、开窗、充电…）。
///
/// 资源走自定义 scheme 而不是 `file://`：渲染器用了 ES module 和 Web Worker，
/// file:// 下同源策略会把 module 和 worker 一起拦掉。
struct CarModel3DView: UIViewRepresentable {
    /// 解压好的资源目录（含 index.html）。
    var root: URL
    /// 车型参数，来自 `carpicture/3d/key` 的 modelParam。
    var param: CarModelParam
    /// 资源目录反推出来的车型别名，`Lafa5` 这种。接口不给，只能从解压结果拿。
    var assetAlias: String?
    /// 当前车况。变了就往渲染器推一次。
    var state: VehicleState?
    /// 首帧渲染出来的回调，用来把占位图撤掉。
    var onReady: () -> Void
    /// 渲染失败（车型资源不全、WebGL 起不来）时回调，让上层退回 2D。
    var onFailure: (() -> Void)?
    /// 渲好之后截下来的整张画布（背景透明）。桌面卡片的车图只能从这里来——
    /// 3D 车的资源包里没有 2D 图层，`composeCarImage()` 那条路一次都跑不了。
    var onSnapshot: ((UIImage) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onFailure: onFailure, onSnapshot: onSnapshot)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(CarModelSchemeHandler(root: root), forURLScheme: Self.scheme)
        // 渲染器的回调只走 window.prompt，而 WKWebView 的 prompt 面板回调并不总能送达
        // （面板不可见时 WebKit 会直接吞掉）。所以把 prompt 改写成 messageHandler，
        // 走 WKScriptMessageHandler 这条稳定通道。
        configuration.userContentController.add(context.coordinator, name: "leap")
        let bridge = WKUserScript(
            source: """
            window.prompt = function (name, arg) {
              window.webkit.messageHandlers.leap.postMessage({ name: name, arg: String(arg ?? '') });
              return null;
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(bridge)
        // 渲染器自带手势，交给它处理；我们只在外面套 SwiftUI。
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 页面本身不滚动，滚动交给外面的 ScrollView。
        webView.scrollView.isScrollEnabled = false
        context.coordinator.webView = webView

        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://model/index.html")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.param = param
        context.coordinator.assetAlias = assetAlias
        context.coordinator.push(state: state)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // WebGL 上下文不主动放，切走后还会在后台占着显存。
        webView.loadHTMLString("", baseURL: nil)
        // 排着的那次截图要作废：页面已经被清空，再截就是一张白板。
        coordinator.cancelPendingSnapshot()
    }

    static let scheme = "leapcar"

    /// H5 3.24.2 的 init 收到 offset/radius 后却向 generateCar 传两个 undefined，
    /// 强制启用面向全屏页面的自动取景。只适配已核对的函数签名和调用点，
    /// 恢复参数透传，使初始化、自动取景开关及返回默认视角使用同一份距离。
    /// 在读取时适配，因此已缓存的资源也生效，不改下载包或其它版本的调用。
    static func rendererSource(_ source: String) -> String {
        let signature = "function e(t,n,r,i,o,a,s,l,c,u,h)"
        let call = "generateCar(t,n,r,i,o,a,s,void 0,void 0,d,v,f,_,m,g)"
        guard let start = source.range(of: "function _init(){"),
              let end = source.range(of: "function parseServerJson", range: start.upperBound..<source.endIndex)
        else { return source }
        let range = start.lowerBound..<end.lowerBound
        let initializer = String(source[range])
        guard initializer.contains(signature), initializer.components(separatedBy: call).count == 2
        else { return source }
        return source.replacingCharacters(in: range, with: initializer.replacingOccurrences(
            of: call, with: "generateCar(t,n,r,i,o,a,s,l,c,d,v,f,_,m,g)"))
    }

    /// 回传给卡片那张图的最大宽度。和 `CarImageCache` 缩到的尺寸对齐，
    /// 页面里先缩一道是为了别让一张几 MB 的 base64 走 JS 桥。
    fileprivate static let snapshotMaxWidth = 960

    /// 抓图脚本。抽成一处是为了让测试拿同一段去跑——它依赖的全是渲染器内部结构
    /// （`window.viewer` 上的 renderer/scene/camera），改坏了编译器一句话都不会说。
    static func snapshotScript(maxWidth: Int) -> String {
        """
            (function () {
              var v = window.viewer;
              if (!v || !v.renderer || !v.scene) return '';
              // 相机在渲染器里叫什么没个准，三条路依次试。
              var cam = (v.camera && v.camera.isCamera) ? v.camera : null;
              if (!cam) {
                for (var k in v) {
                  try { var o = v[k]; if (o && o.isCamera) { cam = o; break; } } catch (e) {}
                }
              }
              if (!cam) { v.scene.traverse(function (o) { if (!cam && o.isCamera) cam = o; }); }
              if (!cam) return '';
              try { v.renderer.render(v.scene, cam); } catch (e) { return ''; }
              var src = v.renderer.domElement;
              if (!src || !src.width || !src.height) return '';
              var scale = Math.min(1, \(maxWidth) / src.width);
              var out = document.createElement('canvas');
              out.width = Math.round(src.width * scale);
              out.height = Math.round(src.height * scale);
              try {
                out.getContext('2d').drawImage(src, 0, 0, out.width, out.height);
                return out.toDataURL('image/png');
              } catch (e) { return ''; }
            })();
        """
    }

    // MARK: - Coordinator

    // iOS 26 SDK 起 WKUIDelegate / WKNavigationDelegate / WKScriptMessageHandler 都是 @MainActor 协议；
    // 类不标 @MainActor 时，delegate 方法因 actor 隔离对不上被判「未实现」（nearly matches 警告），
    // 原生 prompt fallback 因此静默失效。WebView 本就活在主线程，这里补上隔离标注。
    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var param: CarModelParam?
        var assetAlias: String?
        private let onReady: () -> Void
        private let onFailure: (() -> Void)?
        private let onSnapshot: ((UIImage) -> Void)?
        /// 待截的那一次。车况连着变时只截最后一次，前面的排队作废。
        private var snapshotTask: Task<Void, Never>?
        /// 模型加载完之前推状态没用，渲染器还没建好节点。
        private var isModelLoaded = false
        /// 只推变化，避免每次轮询都重放一遍动画。
        private var lastPushed: String?
        /// 首帧兜底：`newInit` 真正调下去之后，渲染器要么给首帧、要么报错——
        /// 两个都没等到就是回调丢了，退 2D。计时必须从 `onInitCalled` 起，
        /// 不能从视图创建起：视图可能被设置页盖着，布局没跑、模型压根还没开始起。
        private var firstFrameWatchdog: Task<Void, Never>?

        init(onReady: @escaping () -> Void,
             onFailure: (() -> Void)?,
             onSnapshot: ((UIImage) -> Void)?) {
            self.onReady = onReady
            self.onFailure = onFailure
            self.onSnapshot = onSnapshot
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let param else { return }
            // 渲染器是 ES module，`didFinish` 时 index.js 还没跑完，
            // window.newInit 要等它初始化才挂上来——直接调必然 undefined。
            // 所以把「等就绪再启动」整段交给页面自己轮询。
            //
            // 画布尺寸也在页面里等：`didFinish` 可能赶在 SwiftUI 布局之前
            // （视图刚从「关掉车模型」重新打开时必现），那时 bounds 还是零，
            // 用它起模型，渲染器会按一块小画布取景——车就显得特别小。
            // `innerWidth` 一变正就是布局到位了，那一刻取的才是真实尺寸。
            let script = """
            window.IOSWebview = true;
            window.onerror = function (m, s, l) { window.prompt('onJSError', m + ' @' + l); };
            window.addEventListener('unhandledrejection', function (e) {
              window.prompt('onReject', String(e.reason && (e.reason.message || e.reason)));
            });
            (function () {
              var tries = 0;
              function start() {
                if (typeof window.newInit === 'function') {
                  if (window.innerWidth > 0) {
                    window.prompt('onInitCalled', '');
                    // inland 是反直觉的：渲染器里 0 才是国内、1 是国外
                    // （`0===Number(r)?"国内":1===Number(r)?"国外"`）。
                    // 它是资源文件名的第一段，传 1 会去找 `C11_2026_1_0_0_…csv`、
                    // `Lafa5_1_license.jpg`，而包里全是 `_0_…` 那套，整批 404。
                    var app = JSON.stringify({
                      width: window.innerWidth, height: window.innerHeight, energy: 0, inland: 0
                    });
                    try {
                      window.newInit('\(param.serverJSON(alias: assetAlias))', app);
                    } catch (e) {
                      window.prompt('onInitThrow', String(e && (e.message || e)));
                    }
                    return;
                  }
                  // newInit 到位了、布局还没到——在设置页里刚打开「显示车模型」时，
                  // 首页被盖在下面，这个 WebView 可能很久都量不到尺寸。
                  // 这不是失败，等多久都行；布局一到立刻按真实尺寸起模型。
                  setTimeout(start, 100);
                  return;
                }
                // 10 秒还没挂上来就是不会来了。只有这条路才算失败。
                if (++tries > 200) { window.prompt('onInitTimeout'); return; }
                setTimeout(start, 50);
              }
              start();
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] _, _ in
                // 场景可能在 newInit 后的任意一帧建好，从现在起就盯着抠。
                self?.startBlendWatcher()
            }
        }

        /// 被改写过的 `window.prompt` 把回调送到这里（见 makeUIView 里注入的桥）。
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String else { return }
            handleCallback(name, argument: body["arg"] as? String)
        }

        private func handleCallback(_ name: String, argument: String?) {
            // 渲染器加载不下去时只在 printLog 里说一声就停住，不抛异常也不再回调，
            // 光等首帧会一直等下去。认出这句就退回 2D。
            let rendererGaveUp = name == "printLog" && argument?.contains("程序结束") == true
            if rendererGaveUp || name == "onInitThrow" || name == "onInitTimeout" {
                firstFrameWatchdog?.cancel()
                onFailure?()
                return
            }
            if name == "onInitCalled" {
                firstFrameWatchdog?.cancel()
                firstFrameWatchdog = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !self.isModelLoaded else { return }
                    self.onFailure?()
                }
                return
            }
            if name == "onFirstFrame" || name == "onFullCarLoaded" {
                // 场景这时才建好，抠背景要等到这一刻。
                // onFullCarLoaded 时高精模型换过一轮，环境贴图要重烘一次。
                blendIntoBackground()
                firstFrameWatchdog?.cancel()
                // 首帧一张、高精模型换上来后再一张，给桌面卡片用。
                // 放在 `guard` 前面：`onFullCarLoaded` 时 isModelLoaded 已经是 true，
                // 写在后面就只有首帧那张低精模型会被截走。
                scheduleSnapshot()
                guard !isModelLoaded else { return }
                isModelLoaded = true
                onReady()
                replayLastState()
            }
        }

        /// 万一注入没生效，原生 prompt 面板这条路也接着。
        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (String?) -> Void) {
            handleCallback(prompt, argument: defaultText)
            completionHandler(nil)
        }

        /// 把车况映射成渲染器的命令数组。
        ///
        /// 命令协议来自渲染器自己的 `controller` 分发：
        /// `[{ type: 'Door', command: [{ type: 'LeftFront_Door', open: true }] }, …]`
        func push(state: VehicleState?) {
            guard let state else { return }
            let commands = Self.commands(for: state)
            guard commands != lastPushed else { return }
            lastPushed = commands
            guard isModelLoaded else { return }
            webView?.evaluateJavaScript("window.controller(\(commands));")
            // 门窗动画放完了才是卡片该看到的样子。
            scheduleSnapshot()
        }

        // MARK: - 卡片车图

        /// 渲染器把这一轮动画放完之后截一张。
        ///
        /// 延时是等动画：开门、开窗、充电都是渲染器自己放的补间，命令发下去的那一刻
        /// 车还停在上一个姿势。连着来好几次状态变化时只留最后一次——前面排队的作废，
        /// 免得中间姿势被写进卡片。
        private func scheduleSnapshot() {
            guard onSnapshot != nil else { return }
            snapshotTask?.cancel()
            snapshotTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.captureSnapshot()
            }
        }

        /// 从 WebGL 画布自己取图。
        ///
        /// **不能用 `WKWebView.takeSnapshot`**：这个 WebView 是 `isOpaque = false` 的
        /// （首页要透出自己的背景），而透明 WebView 的快照在 iOS 上回来是一张全空的图——
        /// 实测把同一个 WebView 改成不透明就能截到东西，改回透明就又是空的。
        ///
        /// 所以让页面自己交图：先按当前相机重渲一帧，再立刻 `toDataURL`。
        /// 顺序不能反——渲染器建 context 时没开 `preserveDrawingBuffer`，
        /// 不在同一个 JS 回合里读，缓冲区已经被清空，读出来是全透明。
        /// 缩放也放在页面里做：整张画布 base64 有好几 MB，先缩到卡片用得上的宽度再回传。
        ///
        /// 背景是 `blendIntoBackground()` 抠掉的（`setClearAlpha(0)`），
        /// 所以出来的图四周本来就是透明的，正好交给 `CarImageCache` 裁边。
        private func captureSnapshot() {
            guard let webView, let onSnapshot else { return }
            let script = CarModel3DView.snapshotScript(maxWidth: CarModel3DView.snapshotMaxWidth)
            webView.evaluateJavaScript(script) { value, _ in
                guard let dataURL = value as? String,
                      let comma = dataURL.firstIndex(of: ","),
                      dataURL.hasPrefix("data:image/png;base64,"),
                      let data = Data(
                          base64Encoded: String(dataURL[dataURL.index(after: comma)...])
                      ),
                      let image = UIImage(data: data) else {
                    return
                }
                onSnapshot(image)
            }
        }

        /// 把渲染器自带的户外场景抠掉，只留车。
        ///
        /// 官方那套天空盒 + 雪地是给全屏爱车页做的，嵌到我们首页里就是两种视觉语气。
        /// 但天空盒不能直接删——车漆的高光和镀铬件的反射全来自它。所以先把当前场景
        /// 烘成一张环境贴图挂到 `scene.environment`，再隐藏天空盒和地面：
        /// 反射还在，背景透出我们自己的界面。
        private func blendIntoBackground() {
            let script = """
            (function () {
              var v = window.viewer;
              if (!v || !v.scene || !v.renderer || !window.THREE) return 'no scene';
              var scene = v.scene, renderer = v.renderer;
              try {
                var pmrem = new window.THREE.PMREMGenerator(renderer);
                if (pmrem.compileEquirectangularShader) pmrem.compileEquirectangularShader();
                scene.environment = pmrem.fromScene(scene, 0, 0.1, 1000).texture;
              } catch (e) { /* 烘不出来就退化成没有反射，仍比露着雪地强 */ }
              scene.children.forEach(function (c) { if (c.isMesh) c.visible = false; });
              scene.background = null;
              renderer.setClearColor(0x000000, 0);
              renderer.setClearAlpha(0);
              document.body.style.background = 'transparent';
              document.documentElement.style.background = 'transparent';
              return 'blended';
            })();
            """
            webView?.evaluateJavaScript(script)
        }

        /// 场景一建好就抠背景，别等首帧。
        ///
        /// 渲染器建好 `window.viewer` 到吐出第一帧之间有几十帧的空档，
        /// 只在 `onFirstFrame` 里抠的话，用户会先看到一闪而过的雪地。
        /// 所以从启动脚本开始就轮询，`viewer` 一出现立刻抠掉。
        private func startBlendWatcher() {
            let script = """
            (function () {
              if (window.__leapBlendWatcher) return 'already';
              window.__leapBlendWatcher = true;
              var tries = 0;
              function strip() {
                var v = window.viewer;
                if (v && v.scene && v.renderer) {
                  v.scene.children.forEach(function (c) { if (c.isMesh) c.visible = false; });
                  v.scene.background = null;
                  v.renderer.setClearColor(0x000000, 0);
                  v.renderer.setClearAlpha(0);
                  document.body.style.background = 'transparent';
                  document.documentElement.style.background = 'transparent';
                }
                // 高精模型换上来时会再加场景物件，所以整个加载期都盯着。
                if (++tries < 400) setTimeout(strip, 30);
              }
              strip();
              return 'watching';
            })();
            """
            webView?.evaluateJavaScript(script)
        }

        func cancelPendingSnapshot() {
            snapshotTask?.cancel()
            snapshotTask = nil
        }

        private func replayLastState() {
            guard let commands = lastPushed else { return }
            webView?.evaluateJavaScript("window.controller(\(commands));")
        }

        static func commands(for state: VehicleState) -> String {
            var groups: [String] = []

            let doors: [(String, Bool?)] = [
                ("LeftFront_Door", state.bool(.driverDoor)),
                ("RightFront_Door", state.bool(.passengerDoor)),
                ("LeftRear_Door", state.bool(.leftRearDoor)),
                ("RightRear_Door", state.bool(.rightRearDoor))
            ]
            // 读不到的门不发命令——不知道开没开，不等于关着。
            let doorCommands = doors.compactMap { name, open -> String? in
                guard let open else { return nil }
                return "{\"type\":\"\(name)\",\"open\":\(open)}"
            }
            var allDoorCommands = doorCommands
            if let trunk = state.trunkOpen {
                allDoorCommands.append("{\"type\":\"Trunk\",\"open\":\(trunk)}")
            }
            if !allDoorCommands.isEmpty {
                groups.append("{\"type\":\"Door\",\"command\":[\(allDoorCommands.joined(separator: ","))]}")
            }

            let windows: [(String, Int?)] = [
                ("LeftFront_Window", state.leftFrontWindow),
                ("RightFront_Window", state.rightFrontWindow),
                ("LeftRear_Window", state.leftRearWindow),
                ("RightRear_Window", state.rightRearWindow)
            ]
            let windowCommands = windows.compactMap { name, openness -> String? in
                guard let openness else { return nil }
                return "{\"type\":\"\(name)\",\"open\":\(openness > 0)}"
            }
            if !windowCommands.isEmpty {
                groups.append("{\"type\":\"Window\",\"command\":[\(windowCommands.joined(separator: ","))]}")
            }

            groups.append("{\"type\":\"Charge\",\"command\":"
                + "[{\"type\":\"Charge\",\"open\":\(state.isCharging)}]}")

            return "[\(groups.joined(separator: ","))]"
        }
    }
}

/// 把自定义 scheme 的请求映射到解压目录里的文件。
///
/// 只读、只在目录内取文件，路径越界一律 404。
private final class CarModelSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // 路径可能带百分号编码（包里有中文名的 CSV）。
        let relative = (url.path.removingPercentEncoding ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.path),
              var data = try? Data(contentsOf: target) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404,
                                            httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        if relative == "index.js", let source = String(data: data, encoding: .utf8) {
            data = Data(CarModel3DView.rendererSource(source).utf8)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: target.pathExtension),
                "Content-Length": String(data.count),
                // 渲染器是 ES module，缺这个头浏览器不给执行。
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "csv": return "text/csv; charset=utf-8"
        case "fbx": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
