package org.yipao.app.ui.components

import android.annotation.SuppressLint
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.MotionEvent
import android.webkit.JsPromptResult
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.yipao.app.core.CarModelParam
import org.yipao.app.core.DiagLog
import org.yipao.app.core.VehicleSignal
import org.yipao.app.core.VehicleState
import java.io.File
import org.json.JSONTokener

/// 官方那套 3D 车模型，跑在 WebView 里。
///
/// 渲染器是零跑自己的 WebGL 包（Three.js + FBX），我们只做三件事：
/// 把解压好的资源喂给它、按车型参数调 `newInit` 起模型、把车况变化用
/// `window.controller` 推进去（开门、开窗、充电…）。
///
/// **资源不走 `file://`**：渲染器用了 ES module 和 Web Worker，`file://` 下是
/// 不透明源（opaque origin），module 和 worker 会被同源策略一起拦掉。所以挂一个
/// 假的 https 源，请求全部由 [shouldInterceptRequest] 就地喂本地文件——
/// `appassets.androidplatform.net` 是谷歌为这个用途留的保留域名，永远解析不出去，
/// 拦漏了也只会失败，不会真的发到网上。
@Composable
fun CarModel3DView(
    root: File,
    param: CarModelParam,
    assetAlias: String?,
    state: VehicleState?,
    onReady: () -> Unit,
    onFailure: () -> Unit,
    modifier: Modifier = Modifier,
    onSnapshot: ((ByteArray) -> Unit)? = null,
    active: Boolean = true,
) {
    // 回调每次重组都是新的 lambda，直接闭进 Bridge 里会一直用第一次那份。
    val ready = rememberUpdatedState(onReady)
    val failed = rememberUpdatedState(onFailure)
    val snapshot = rememberUpdatedState(onSnapshot)
    val bridge = remember(root) {
        CarModelBridge(
            root,
            onReady = { ready.value() },
            onFailure = { failed.value() },
            onSnapshot = { png -> snapshot.value?.invoke(png) },
        )
    }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            val debuggable =
                (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            if (debuggable) WebView.setWebContentsDebuggingEnabled(true)
            WebView(context).apply { bridge.attach(this) }
        },
        update = { webView ->
            if (active) webView.onResume() else webView.onPause()
            bridge.param = param
            bridge.assetAlias = assetAlias
            // 页面在这里才开始加载，不在 factory 里：`onPageFinished` 要用 param 拼
            // `newInit` 的入参，而 param 是随 update 进来的。在 factory 里就 load，
            // 页面有可能在第一次 update 之前就加载完，那一次 bootstrap 会空手而归。
            bridge.startIfNeeded()
            bridge.push(state)
        },
        onRelease = { webView ->
            bridge.detach()
            // WebGL 上下文不主动放，切走之后还会在后台占着显存。
            webView.loadUrl("about:blank")
            webView.destroy()
        },
    )
}

/// WebView 的装配、桥接与命令下发。
///
/// 单独成类而不是塞进 Composable：`shouldInterceptRequest` 跑在 WebView 自己的
/// 工作线程上，`onJsPrompt` 跑在主线程，两边都要拿到同一份 root 和状态。
private class CarModelBridge(
    root: File,
    private val onReady: () -> Unit,
    private val onFailure: () -> Unit,
    /// 渲好之后截下来的整张画布（PNG，背景透明）。桌面小组件的车图只能从这里来——
    /// 3D 车的资源包里没有 2D 图层，`composeCarImage()` 那条路一次都跑不了。
    private val onSnapshot: (ByteArray) -> Unit,
) {
    private val resources = CarModelResourceFiles(root)

    var param: CarModelParam? = null
    var assetAlias: String? = null

    private var webView: WebView? = null
    private val main = Handler(Looper.getMainLooper())

    /// 模型加载完之前推状态没用，渲染器还没建好节点。
    private var isModelLoaded = false

    /// 只推变化，避免每次轮询都重放一遍动画。
    private var lastPushed: String? = null

    /// 首帧兜底：`newInit` 真正调下去之后，渲染器要么给首帧、要么报错——
    /// 两个都没等到就是回调丢了，退 2D。计时必须从 `onInitCalled` 起，
    /// 不能从视图创建起：视图可能被别的页面盖着，布局没跑、模型压根还没开始起。
    private val firstFrameWatchdog = Runnable {
        if (isModelLoaded) return@Runnable
        DiagLog.note("[3d] newInit 后 15 秒没等到首帧，退回 2D")
        onFailure()
    }

    /// 已经报过失败就别再报第二次：上层一收到就把这层撤了，重复回调只是噪音。
    private var didFail = false

    @SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
    fun attach(webView: WebView) {
        this.webView = webView
        webView.settings.apply {
            javaScriptEnabled = true
            // 渲染器把解码好的模型缓存在 IndexedDB 里，没有它每次都要重解 FBX。
            domStorageEnabled = true
            // 资源全部由拦截器喂，不需要给页面开任何本地访问口子。
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = false
        }
        // 背景透明，车底下透出我们自己的界面（渲染器那套天空盒和雪地会被抠掉，
        // 见 startBlendWatcher）。三处都要设，少一处就会露出白底。
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.overScrollMode = WebView.OVER_SCROLL_NEVER
        // 首页是一整列可滚动内容，不抢的话竖着一拖就被外层滚走，转不动车。
        // 代价是从车图上起手划不动页面——和 iOS 上一样，转车优先。
        webView.setOnTouchListener { view, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                view.parent?.requestDisallowInterceptTouchEvent(true)
            }
            false
        }
        webView.webViewClient = client
        webView.webChromeClient = chrome
    }

    private var didStart = false

    fun startIfNeeded() {
        if (didStart) return
        didStart = true
        webView?.loadUrl("$ORIGIN/index.html")
    }

    fun detach() {
        main.removeCallbacks(firstFrameWatchdog)
        main.removeCallbacks(snapshotTask)
        webView = null
    }

    // MARK: - 资源

    private val client = object : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String?) {
            bootstrap()
        }

        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = request.url
            if (url.host != HOST || url.scheme != "https") return null
            // 路径可能带百分号编码（包里有中文名的 CSV）。`Uri.getPath` 已经解过码。
            val relative = (url.path ?: "").trim('/')
            val target = resources.resolve(relative)
            if (target == null) {
                DiagLog.note("[3d] 404 $relative")
                return WebResourceResponse("text/plain", "utf-8", 404, "Not Found", null, null)
            }
            val mime = mimeType(target.extension)
            return WebResourceResponse(
                mime,
                if (mime.startsWith("text/") || mime == "application/json") "utf-8" else null,
                200,
                "OK",
                // 渲染器是 ES module，缺这个头浏览器不给执行。
                mapOf("Access-Control-Allow-Origin" to "*"),
                if (relative == "index.js") {
                    CarModelRendererSource.adapt(target.readText()).byteInputStream()
                } else target.inputStream(),
            )
        }
    }

    // MARK: - 桥

    private val chrome = object : WebChromeClient() {
        /// 渲染器所有回调都走 `window.prompt(name, arg)`，安卓这边落到这里。
        override fun onJsPrompt(
            view: WebView,
            url: String?,
            message: String?,
            defaultValue: String?,
            result: JsPromptResult,
        ): Boolean {
            handleCallback(message.orEmpty(), defaultValue)
            result.confirm(null)
            return true
        }
    }

    private fun handleCallback(name: String, argument: String?) {
        // 渲染器加载不下去时只在 printLog 里说一声就停住，不抛异常也不再回调，
        // 光等首帧会一直等下去。认出这句就退回 2D。
        val gaveUp = name == "printLog" && argument?.contains("程序结束") == true
        if (gaveUp || name == "onInitThrow" || name == "onInitTimeout") {
            DiagLog.note("[3d] 渲染失败，退回 2D：$name ${argument.orEmpty()}")
            main.removeCallbacks(firstFrameWatchdog)
            if (!didFail) {
                didFail = true
                onFailure()
            }
            return
        }
        if (name == "onInitCalled") {
            main.removeCallbacks(firstFrameWatchdog)
            main.postDelayed(firstFrameWatchdog, 15_000)
            return
        }
        if (name == "onFirstFrame" || name == "onFullCarLoaded") {
            // 场景这时才建好，抠背景要等到这一刻。
            // onFullCarLoaded 时高精模型换过一轮，环境贴图要重烘一次。
            blendIntoBackground()
            main.removeCallbacks(firstFrameWatchdog)
            // 首帧一张、高精模型换上来后再一张，给桌面小组件用。
            // 放在下面这句 `return` 前面：`onFullCarLoaded` 时 isModelLoaded 已经是 true，
            // 写在后面就只有首帧那张低精模型会被截走。
            scheduleSnapshot()
            if (isModelLoaded) return
            isModelLoaded = true
            revealModel()
            // 成功也记一笔：手上没有能跑 3D 的模拟器，真机上到底走没走通只能靠这条。
            DiagLog.note("[3d] 首帧已出，3D 接管")
            onReady()
            replayLastState()
        }
    }

    // MARK: - 启动

    /// 页面加载完就把启动脚本打进去。
    ///
    /// 渲染器是 ES module，`onPageFinished` 时 index.js 还没跑完，`window.newInit`
    /// 要等它初始化才挂上来——直接调必然 undefined。所以把「等就绪再启动」整段
    /// 交给页面自己轮询。
    ///
    /// 画布尺寸也在页面里等：`onPageFinished` 可能赶在 Compose 布局之前（视图刚从
    /// 「关掉车模型」重新打开时必现），那时 innerWidth 还是 0，用它起模型渲染器会
    /// 按一块小画布取景——车就显得特别小。`innerWidth` 一变正就是布局到位了。
    private fun bootstrap() {
        val param = param ?: return
        val script = """
            // 渲染器按这个标志决定回调走哪条路：为真时一律走 window.prompt，
            // 正是安卓 onJsPrompt 接得住的那条。这里报 iOS 不是为了伪装平台，
            // 是为了选中这条我们实现了的回调通道。
            window.IOSWebview = true;
            // 淡入留在 Chromium 内部做，不能对宿主 WebView 使用 Compose alpha；后者会
            // 把 GLFunctor 放进 HWUI 离屏层，部分 Android 15 ROM 会因此 native 崩溃。
            (function () {
              var style = document.createElement('style');
              style.textContent =
                'html:not(.leap-model-ready) canvas{opacity:0!important}' +
                'html.leap-model-ready canvas{opacity:1;transition:opacity 350ms ease}';
              document.head.appendChild(style);
            })();
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
                      window.newInit('${param.serverJSON(assetAlias)}', app);
                    } catch (e) {
                      window.prompt('onInitThrow', String(e && (e.message || e)));
                    }
                    return;
                  }
                  // newInit 到位了、布局还没到——刚打开「显示车模型」时首页被设置页
                  // 盖在下面，这个 WebView 可能很久都量不到尺寸。这不是失败，等多久
                  // 都行；布局一到立刻按真实尺寸起模型。
                  setTimeout(start, 100);
                  return;
                }
                // 10 秒还没挂上来就是不会来了。只有这条路才算失败。
                if (++tries > 200) { window.prompt('onInitTimeout'); return; }
                setTimeout(start, 50);
              }
              start();
            })();
        """.trimIndent()
        webView?.evaluateJavascript(script) {
            // 场景可能在 newInit 后的任意一帧建好，从现在起就盯着抠。
            startBlendWatcher()
        }
    }

    /// WebView 始终以正常硬件层绘制，只改变网页 canvas 的透明度。
    private fun revealModel() {
        webView?.evaluateJavascript(
            "document.documentElement.classList.add('leap-model-ready');",
            null,
        )
    }

    // MARK: - 抠背景

    /// 把渲染器自带的户外场景抠掉，只留车。
    ///
    /// 官方那套天空盒 + 雪地是给全屏爱车页做的，嵌到我们首页里就是两种视觉语气。
    /// 但天空盒不能直接删——车漆的高光和镀铬件的反射全来自它。所以先把当前场景
    /// 烘成一张环境贴图挂到 `scene.environment`，再隐藏天空盒和地面：
    /// 反射还在，背景透出我们自己的界面。
    private fun blendIntoBackground() {
        webView?.evaluateJavascript(
            """
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
            """.trimIndent(),
            null,
        )
    }

    /// 场景一建好就抠背景，别等首帧。
    ///
    /// 渲染器建好 `window.viewer` 到吐出第一帧之间有几十帧的空档，
    /// 只在 `onFirstFrame` 里抠的话，用户会先看到一闪而过的雪地。
    /// 所以从启动脚本开始就轮询，`viewer` 一出现立刻抠掉。
    private fun startBlendWatcher() {
        webView?.evaluateJavascript(
            """
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
            """.trimIndent(),
            null,
        )
    }

    // MARK: - 抓图

    /// 渲染完两秒后抓一张。延时是给动画留的：门窗、充电口盖都要放完才是定妆照，
    /// 中途截会截到半开的门。重复排队只保留最后一次。
    private val snapshotTask = Runnable { captureSnapshot() }

    private fun scheduleSnapshot() {
        main.removeCallbacks(snapshotTask)
        main.postDelayed(snapshotTask, 2_000)
    }

    /// **不能把 WebView 画进 Canvas 来截**：这块 WebView 是透明的
    /// （`setBackgroundColor(TRANSPARENT)`），而 WebGL 画布的内容不在 View 的
    /// 软件层里——那么截出来是一整张空图。iOS 上 `takeSnapshot` 也是同样的空。
    ///
    /// 所以让页面自己出图：同一个 JS 回合里先 `render` 再 `toDataURL`。
    /// 顺序不能反——渲染器建 WebGL 上下文时没开 `preserveDrawingBuffer`，
    /// 一出这个回合绘制缓冲就被清了，`toDataURL` 拿到的还是空图。
    private fun captureSnapshot() {
        val webView = webView ?: return
        webView.evaluateJavascript(CarSnapshotScript.of(SNAPSHOT_MAX_WIDTH)) { result ->
            val dataURL = runCatching { JSONTokener(result).nextValue() as? String }.getOrNull()
            val comma = dataURL?.indexOf(',') ?: -1
            if (dataURL == null || !dataURL.startsWith("data:image/png;base64,") || comma < 0) {
                DiagLog.note("[3d] 小组件车图没抓到")
                return@evaluateJavascript
            }
            val png = runCatching {
                Base64.decode(dataURL.substring(comma + 1), Base64.DEFAULT)
            }.getOrNull()
            if (png == null || png.isEmpty()) {
                DiagLog.note("[3d] 小组件车图解不出来")
                return@evaluateJavascript
            }
            onSnapshot(png)
        }
    }

    // MARK: - 车况下发

    fun push(state: VehicleState?) {
        if (state == null) return
        val commands = CarModelCommands.of(state)
        if (commands == lastPushed) return
        lastPushed = commands
        if (!isModelLoaded) return
        webView?.evaluateJavascript("window.controller($commands);", null)
        // 门窗动画放完了才是小组件该看到的样子。
        scheduleSnapshot()
    }

    private fun replayLastState() {
        val commands = lastPushed ?: return
        webView?.evaluateJavascript("window.controller($commands);", null)
    }

    companion object {
        private const val HOST = "appassets.androidplatform.net"
        private const val ORIGIN = "https://$HOST"

        /// 回传给小组件那张图的最大宽度。页面里先缩一道是为了别让一张几 MB 的
        /// base64 走 `evaluateJavascript` 的返回值——那是一次跨进程的字符串拷贝。
        /// 落盘还会再缩到 360（见 `CarImageCache`），这里留一倍余量给裁边。
        private const val SNAPSHOT_MAX_WIDTH = 720

        private fun mimeType(extension: String): String = when (extension.lowercase()) {
            "html" -> "text/html"
            "js", "mjs" -> "text/javascript"
            "json" -> "application/json"
            "css" -> "text/css"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "csv" -> "text/csv"
            "fbx" -> "application/octet-stream"
            else -> "application/octet-stream"
        }
    }
}

/// 从渲染器里抓一张车图的脚本。
///
/// 单独拎出来是为了能用单测钉住：它依赖的全是渲染器内部结构（`window.viewer` 上的
/// renderer/scene/camera），改坏了编译器一句话都不会说，桌面上的车图会悄悄变空。
internal object CarSnapshotScript {

    fun of(maxWidth: Int): String = """
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
          var scale = Math.min(1, $maxWidth / src.width);
          var out = document.createElement('canvas');
          out.width = Math.round(src.width * scale);
          out.height = Math.round(src.height * scale);
          try {
            out.getContext('2d').drawImage(src, 0, 0, out.width, out.height);
            return out.toDataURL('image/png');
          } catch (e) { return ''; }
        })();
    """.trimIndent()
}

/// 把车况映射成渲染器的命令数组。
///
/// 单独拎出来是为了能用纯 JVM 单测钉住：这串 JSON 一个字段名写错，渲染器不报错、
/// 只是那扇门永远不动——和 2D 层序一样属于「错了也没人告诉你」的地方。
internal object CarModelCommands {

    /// 把车况映射成渲染器的命令数组。
    ///
    /// 命令协议来自渲染器自己的 `controller` 分发：
    /// `[{ type: 'Door', command: [{ type: 'LeftFront_Door', open: true }] }, …]`
    fun of(state: VehicleState): String {
        val groups = mutableListOf<String>()

        val doors = listOf(
            "LeftFront_Door" to state.bool(VehicleSignal.DriverDoor),
            "RightFront_Door" to state.bool(VehicleSignal.PassengerDoor),
            "LeftRear_Door" to state.bool(VehicleSignal.LeftRearDoor),
            "RightRear_Door" to state.bool(VehicleSignal.RightRearDoor),
        )
        // 读不到的门不发命令——不知道开没开，不等于关着。
        val doorCommands = doors.mapNotNull { (name, open) ->
            open?.let { """{"type":"$name","open":$it}""" }
        }.toMutableList()
        state.trunkOpen?.let { doorCommands += """{"type":"Trunk","open":$it}""" }
        if (doorCommands.isNotEmpty()) {
            groups += """{"type":"Door","command":[${doorCommands.joinToString(",")}]}"""
        }

        val windows = listOf(
            "LeftFront_Window" to state.leftFrontWindow,
            "RightFront_Window" to state.rightFrontWindow,
            "LeftRear_Window" to state.leftRearWindow,
            "RightRear_Window" to state.rightRearWindow,
        )
        val windowCommands = windows.mapNotNull { (name, openness) ->
            openness?.let { """{"type":"$name","open":${it > 0}}""" }
        }
        if (windowCommands.isNotEmpty()) {
            groups += """{"type":"Window","command":[${windowCommands.joinToString(",")}]}"""
        }

        groups += """{"type":"Charge","command":[{"type":"Charge","open":${state.isCharging}}]}"""

        return "[${groups.joinToString(",")}]"
    }
}
