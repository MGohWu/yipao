import WebKit
import JavaScriptCore
import XCTest
@testable import LeapControl

/// 3D 车的桌面卡片车图全靠这段脚本从 WebGL 画布上取。
///
/// 它依赖的是渲染器的内部结构（`window.viewer` 上的 renderer / scene / camera），
/// 编译器管不着，改坏了只会在真机上表现为「卡片又变回剪影」。所以这里拿一个
/// 最小的假 viewer 把整条链路跑一遍：重渲一帧 → 缩放 → toDataURL → 解回 UIImage。
///
/// 尤其要守住**透明背景**：`WKWebView.takeSnapshot` 在透明 WebView 上回来是空图，
/// 正因如此才走的这条路；要是这里的 alpha 也丢了，卡片上就会出现一整块底色。
final class CarSnapshotScriptTests: XCTestCase {
    @MainActor
    func testRendererInitializerForwardsCameraParameters() throws {
        // 3.24.2 的参数顺序及调用点：显式距离不能被改成 undefined，
        // 否则 generateCar 会开启自动取景。
        let source = """
        var received;
        function generateCar() { received = Array.from(arguments); }
        function _init(){return function e(t,n,r,i,o,a,s,l,c,u,h){
          var d='alias',v=5,f=0,_='sdk',m='',g='default';
          generateCar(t,n,r,i,o,a,s,void 0,void 0,d,v,f,_,m,g);
        }}
        function parseServerJson() {}
        _init()('C11',2026,0,0,0,'version',2,0.3,8,370,200);
        """
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(CarModel3DView.rendererSource(source))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("received[7]")?.toDouble(), 0.3)
        XCTAssertEqual(context.evaluateScript("received[8]")?.toDouble(), 8)
        XCTAssertEqual(context.evaluateScript("received[9]")?.toString(), "alias")
        XCTAssertEqual(context.evaluateScript("received[10]")?.toInt32(), 5)
    }

    @MainActor
    func testRendererAdapterLeavesUnknownInitializersUnchanged() {
        let source = "function _init(){generateCar(a,b,c)}function parseServerJson(){}"
        XCTAssertEqual(CarModel3DView.rendererSource(source), source)
    }

    @MainActor
    func testScriptReturnsScaledImageWithTransparentBackground() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        webView.isOpaque = false
        webView.backgroundColor = .clear

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let host = UIViewController()
        host.view.addSubview(webView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        // 假 viewer：画布 600×400，正中间一块 200×140 的红，四周留透明——
        // 和抠掉背景之后的渲染器同一个形状。
        let html = """
        <html><head><meta name="viewport" content="width=device-width"></head>
        <body style="margin:0;background:transparent">
        <canvas id="c" width="600" height="400"></canvas>
        <script>
        var canvas = document.getElementById('c');
        var gl = canvas.getContext('webgl', { alpha: true });
        function draw() {
          gl.viewport(0, 0, 600, 400);
          gl.clearColor(0, 0, 0, 0);
          gl.clear(gl.COLOR_BUFFER_BIT);
          gl.enable(gl.SCISSOR_TEST);
          gl.scissor(200, 130, 200, 140);
          gl.clearColor(1, 0, 0, 1);
          gl.clear(gl.COLOR_BUFFER_BIT);
          gl.disable(gl.SCISSOR_TEST);
        }
        window.viewer = {
          scene: { traverse: function () {} },
          camera: { isCamera: true },
          renderer: { domElement: canvas, render: function () { draw(); } }
        };
        document.title = gl ? 'gl-ok' : 'gl-missing';
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        try await Task.sleep(for: .seconds(2))
        try XCTSkipIf(webView.title != "gl-ok", "这台机器上起不来 WebGL 上下文，脚本没法验")

        let value = try await webView.evaluateJavaScript(
            CarModel3DView.snapshotScript(maxWidth: 240)
        )
        let dataURL = try XCTUnwrap(value as? String)
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"), "脚本没交出图：\(dataURL.prefix(40))")

        let comma = try XCTUnwrap(dataURL.firstIndex(of: ","))
        let data = try XCTUnwrap(Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])))
        let image = try XCTUnwrap(UIImage(data: data))
        let cgImage = try XCTUnwrap(image.cgImage)

        // 600 宽按 240 缩，正好 0.4 倍。
        XCTAssertEqual(cgImage.width, 240)
        XCTAssertEqual(cgImage.height, 160)

        let width = cgImage.width
        let height = cgImage.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(alpha.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        })
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func at(_ x: Int, _ y: Int) -> UInt8 { alpha[y * width + x] }

        XCTAssertGreaterThan(at(width / 2, height / 2), 200, "中间那块内容没取到")
        XCTAssertLessThanOrEqual(at(1, 1), 8, "四周不透明——背景没抠掉，卡片会变成一整块底色")
        XCTAssertLessThanOrEqual(at(width - 2, height - 2), 8, "四周不透明")
    }

    /// 渲染器还没建好 viewer 时脚本必须安静地交白卷，而不是抛异常。
    @MainActor
    func testScriptReturnsEmptyBeforeViewerExists() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        try await Task.sleep(for: .seconds(1))
        let value = try await webView.evaluateJavaScript(CarModel3DView.snapshotScript(maxWidth: 240))
        XCTAssertEqual(value as? String, "")
    }
}
