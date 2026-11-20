import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { CarModelParam } from '../../core/CarModel';
import { VehicleState } from '../../core/LeapModels';
import { VehicleSignal } from '../../core/SignalSchema';
import { DiagLog } from '../../core/DiagLog';

/**
 * 官方那套 3D 车模型，跑在 ArkWeb 的 Web 组件里。
 *
 * 渲染器是零跑自己的 WebGL 包（Three.js + FBX），我们只做三件事：
 * 把解压好的资源喂给它、按车型参数调 `newInit` 起模型、把车况变化用
 * `window.controller` 推进去（开门、开窗、充电…）。
 *
 * 资源走自定义 scheme 而不是 `file://`：渲染器用了 ES module 和 Web Worker，
 * file:// 下同源策略会把 module 和 worker 一起拦掉。自定义 scheme 注册成
 * standard + CORS + fetch，这三项缺一个 module 就加载不起来。
 *
 * 渲染器的回调走 `window.prompt`，鸿蒙这边正好有 `onPrompt` 能接住，
 * 不用像 iOS 那样重写 prompt 再架一条 messageHandler。
 */
@ComponentV2
export struct CarModel3DView {
  /** 解压好的资源目录（含 index.html）。 */
  @Param root: string = '';
  /** 车型参数，来自 `carpicture/3d/key` 的 modelParam。 */
  @Param param: CarModelParam | null = null;
  /** 资源目录反推出来的车型别名，`Lafa5` 这种。接口不给，只能从解压结果拿。 */
  @Param assetAlias: string | null = null;
  /** 当前车况。变了就往渲染器推一次。 */
  @Param state: VehicleState | null = null;
  /** 首帧渲染出来的回调，用来把占位图撤掉。 */
  @Event onReady: () => void = () => {
  };
  /** 渲染失败（车型资源不全、WebGL 起不来）时回调，让上层退回 2D。 */
  @Event onFailure: () => void = () => {
  };
  /**
   * 渲好之后截下来的整张画布（PNG 的 data URL，背景透明）。
   * 服务卡片的车图只能从这里来——3D 车的资源包里没有 2D 图层，
   * `CarSnapshot.render()` 那条路一次都跑不了。
   */
  @Event onSnapshot: (dataURL: string) => void = () => {
  };

  private controller: webview.WebviewController = new webview.WebviewController();
  /** 模型加载完之前推状态没用，渲染器还没建好节点。 */
  private isModelLoaded: boolean = false;
  /** 只推变化，避免每次轮询都重放一遍动画。 */
  private lastPushed: string = '';
  /**
   * 首帧兜底：`newInit` 真正调下去之后，渲染器要么给首帧、要么报错——
   * 两个都没等到就是回调丢了，退 2D。计时必须从 `onInitCalled` 起，
   * 不能从组件创建起：组件可能被设置页盖着，布局没跑、模型压根还没开始起。
   */
  private firstFrameWatchdog: number = -1;
  /** 排在队里的那次抓图。重复排队只保留最后一次。 */
  private snapshotTimer: number = -1;

  private static readonly scheme: string = 'leapcar';
  private static schemeRegistered: boolean = false;

  /**
   * 自定义 scheme 必须在 Web 内核起来之前注册，而且全进程只能注册一次，
   * 重复注册会抛「已初始化」。
   */
  static registerScheme(): void {
    if (CarModel3DView.schemeRegistered) {
      return;
    }
    CarModel3DView.schemeRegistered = true;
    try {
      webview.WebviewController.customizeSchemes([{
        schemeName: CarModel3DView.scheme,
        // 不按标准 scheme 解析的话，ES module 的相对路径解析不出来。
        isStandard: true,
        isSupportCORS: true,
        isSupportFetch: true,
        // 不能开 isLocal。开了会按 file:// 那套本地规则处理，页面的 origin 变成
        // null，`new Worker('leapcar://model/FBX.worker.js')` 直接被同源策略拦下：
        //     Failed to construct 'Worker': ... cannot be accessed from origin 'null'
        // FBX 是在这个 Worker 里解析的，它起不来，车模型就永远等不到首帧。
        isLocal: false
      }]);
    } catch (e) {
      DiagLog.note(`[3d] scheme 注册失败：${e}`);
    }
  }

  aboutToAppear(): void {
    CarModel3DView.registerScheme();
  }

  aboutToDisappear(): void {
    // WebGL 上下文不主动放，切走后还会在后台占着显存。
    if (this.firstFrameWatchdog >= 0) {
      clearTimeout(this.firstFrameWatchdog);
    }
    this.cancelSnapshot();
    try {
      this.controller.loadUrl('about:blank');
    } catch (e) {
      // 组件已经销毁时 controller 无效，忽略即可。
    }
  }

  @Monitor('state')
  onStateChanged(): void {
    this.push();
  }

  build() {
    Web({
      src: `${CarModel3DView.scheme}://model/index.html`,
      controller: this.controller
    })
      // 车模型是透明背景嵌在首页里的，内核默认的白底会盖掉整片背景。
      .backgroundColor(Color.Transparent)
      // 页面本身不滚动，滚动交给外面的 Scroll。
      .overScrollMode(OverScrollMode.NEVER)
      .verticalScrollBarAccess(false)
      .horizontalScrollBarAccess(false)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      // 渲染器自带旋转手势，交给它处理。
      .zoomAccess(false)
      // 注入必须赶在页面脚本之前：window.IOSWebview 决定渲染器走哪条分支，
      // 等到 onPageEnd 再设就晚了——那时 index.js 已经按「不是 App 内嵌」跑过一轮。
      .javaScriptOnDocumentStart([{
        script: 'window.IOSWebview = true;',
        scriptRules: ['*']
      }])
      .onInterceptRequest((event: OnInterceptRequestEvent) => {
        return this.serve(event.request.getRequestUrl());
      })
      .onPageEnd(() => {
        this.startRenderer();
      })
      .onPrompt((event: OnPromptEvent) => {
        this.handleCallback(event.message, event.value);
        event.result.handleCancel();
        return true;
      })
      .onErrorReceive(() => {
        // 单个资源失败不一定致命（渲染器会自己重试低精模型），
        // 真失败由 onInitThrow / 首帧超时兜底。
      })
      .width('100%')
      .height('100%')
  }

  // MARK: - 资源

  /**
   * 把自定义 scheme 的请求映射到解压目录里的文件。
   * 只读、只在目录内取文件，路径越界一律 404。
   */
  private serve(url: string): WebResourceResponse {
    const response = new WebResourceResponse();
    const relative = CarModel3DView.relativePath(url);
    const target = `${this.root}/${relative}`;
    // 路径越界直接拒，别让 ../ 把沙箱里别的文件读出去。
    if (relative.length === 0 || relative.indexOf('..') >= 0) {
      return CarModel3DView.notFound(response);
    }
    try {
      const stat = fileIo.statSync(target);
      const file = fileIo.openSync(target, fileIo.OpenMode.READ_ONLY);
      const bytes = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, bytes);
      fileIo.closeSync(file);
      response.setResponseData(bytes);
      response.setResponseEncoding('utf-8');
      response.setResponseMimeType(CarModel3DView.mimeType(relative));
      response.setResponseCode(200);
      response.setReasonMessage('OK');
      // 渲染器是 ES module，缺这个头浏览器不给执行。
      response.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }]);
      response.setResponseIsReady(true);
      return response;
    } catch (e) {
      DiagLog.note(`[3d] 缺失 ${relative}`);
      return CarModel3DView.missing(response, relative);
    }
  }

  /**
   * 资源缺失时给一个「空的 200」，不给 404。
   *
   * 服务端下发的模型包并不总是齐的——我们这台 C11 的包里就没有 seat_normal、
   * CarPaint_Ao 和 CarRoofConfig。而 ArkWeb 里 404 会让页面的 `fetch` 直接抛
   * `TypeError: Failed to fetch`（不是 resolve 一个 404 响应），渲染器那句
   * `加载车模型颜色配置 失败×` 就是这么来的，整条初始化链跟着断在这儿，
   * 最后表现成「newInit 后没等到首帧」。iOS 的 WKURLSchemeHandler 回 404 时
   * 走的是正常响应，所以那边同样缺文件却能渲出来。
   *
   * 空 CSV 会被解析成一张空表，缺贴图给一张 1×1 透明图——少一张座椅法线、
   * 少一张车漆 AO，无非是材质细节差一点，不该让整辆车都渲不出来。
   */
  private static missing(response: WebResourceResponse, relative: string): WebResourceResponse {
    if (CarModel3DView.isImage(relative)) {
      return CarModel3DView.placeholderImage(response);
    }
    response.setResponseData('');
    response.setResponseEncoding('utf-8');
    response.setResponseMimeType(CarModel3DView.mimeType(relative));
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }]);
    response.setResponseIsReady(true);
    return response;
  }

  private static isImage(path: string): boolean {
    const mime = CarModel3DView.mimeType(path);
    return mime === 'image/png' || mime === 'image/jpeg';
  }

  /** 最小的一张全透明 PNG，67 字节。 */
  private static placeholderImage(response: WebResourceResponse): WebResourceResponse {
    const png: number[] = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ];
    const buffer = new ArrayBuffer(png.length);
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < png.length; i++) {
      bytes[i] = png[i];
    }
    response.setResponseData(buffer);
    response.setResponseMimeType('image/png');
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }]);
    response.setResponseIsReady(true);
    return response;
  }

  private static notFound(response: WebResourceResponse): WebResourceResponse {
    response.setResponseData('');
    response.setResponseEncoding('utf-8');
    response.setResponseMimeType('text/plain');
    response.setResponseCode(404);
    response.setReasonMessage('Not Found');
    response.setResponseHeader([]);
    response.setResponseIsReady(true);
    return response;
  }

  /** `leapcar://model/js/a.js?v=1` → `js/a.js`。路径可能带百分号编码（包里有中文名的 CSV）。 */
  private static relativePath(url: string): string {
    let path = url;
    const schemeEnd = path.indexOf('://');
    if (schemeEnd >= 0) {
      path = path.substring(schemeEnd + 3);
    }
    const slash = path.indexOf('/');
    path = slash >= 0 ? path.substring(slash + 1) : '';
    const query = path.indexOf('?');
    if (query >= 0) {
      path = path.substring(0, query);
    }
    const hash = path.indexOf('#');
    if (hash >= 0) {
      path = path.substring(0, hash);
    }
    try {
      path = decodeURIComponent(path);
    } catch (e) {
      // 不是合法编码就按原样走。
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    return path;
  }

  private static mimeType(path: string): string {
    const dot = path.lastIndexOf('.');
    const ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'html':
        return 'text/html';
      case 'js':
      case 'mjs':
        return 'text/javascript';
      case 'json':
        return 'application/json';
      case 'css':
        return 'text/css';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'csv':
        return 'text/csv';
      default:
        return 'application/octet-stream';
    }
  }

  // MARK: - 启动

  /**
   * 渲染器是 ES module，`onPageEnd` 时 index.js 还没跑完，
   * window.newInit 要等它初始化才挂上来——直接调必然 undefined。
   * 所以把「等就绪再启动」整段交给页面自己轮询。
   *
   * 画布尺寸也在页面里等：`onPageEnd` 可能赶在布局之前（组件刚从
   * 「关掉车模型」重新打开时必现），那时宽高还是零，用它起模型，
   * 渲染器会按一块小画布取景——车就显得特别小。
   * `innerWidth` 一变正就是布局到位了，那一刻取的才是真实尺寸。
   */
  private startRenderer(): void {
    const param = this.param;
    if (param === null) {
      return;
    }
    const script = `
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
              // inland 是资源文件名里的第一段，不是「国内/海外」那种开关：
              // 渲染器拿它拼 C11_2026/C11_2026_<inland>_<rudder>_<energy>_<版本>.csv
              // 这张显隐表，以及 C11_<inland>_license.jpg。包里出的是 0 那一套，
              // 传 1 就是整包 404，最后卡在「加载车模型显隐表错误，程序结束!」。
              var app = JSON.stringify({
                width: window.innerWidth, height: window.innerHeight, energy: 0, inland: 0
              });
              try {
                window.newInit(${JSON.stringify(param.serverJSONWith(this.assetAlias))}, app);
              } catch (e) {
                window.prompt('onInitThrow', String(e && (e.message || e)));
              }
              return;
            }
            // newInit 到位了、布局还没到——在设置页里刚打开「显示车模型」时，
            // 首页被盖在下面，这个 Web 组件可能很久都量不到尺寸。
            // 这不是失败，等多久都行；布局一到立刻按真实尺寸起模型。
            setTimeout(start, 100);
            return;
          }
          // 10 秒还没挂上来就是不会来了。只有这条路才算失败。
          if (++tries > 200) { window.prompt('onInitTimeout', ''); return; }
          setTimeout(start, 50);
        }
        start();
      })();
    `;
    this.run(script);
    // 场景可能在 newInit 后的任意一帧建好，从现在起就盯着抠。
    this.startBlendWatcher();
  }

  private run(script: string): void {
    try {
      this.controller.runJavaScript(script);
    } catch (e) {
      DiagLog.note(`[3d] 执行脚本失败：${e}`);
    }
  }

  private handleCallback(name: string, argument: string): void {
    if (name !== 'printLog') {
      DiagLog.note(`[3d] cb ${name} ${argument}`);
    }
    if (name === 'printLog') {
      // 渲染器把每条日志都写成「car uuid: …\n真正的内容」，换行会被日志系统
      // 拆成两条，grep 出来只剩前缀。压成一行再记。
      DiagLog.note(`[3d] ${argument.replace(/\s*\n\s*/g, ' | ')}`);
    }
    // 渲染器加载不下去时只在 printLog 里说一声就停住，不抛异常也不再回调，
    // 光等首帧会一直等下去。认出这句就退回 2D。
    const rendererGaveUp = name === 'printLog' && argument.indexOf('程序结束') >= 0;
    if (rendererGaveUp || name === 'onInitThrow' || name === 'onInitTimeout') {
      DiagLog.note(`[3d] 渲染失败，退回 2D：${name} ${argument}`);
      this.cancelWatchdog();
      this.onFailure();
      return;
    }
    if (name === 'onInitCalled') {
      this.cancelWatchdog();
      this.firstFrameWatchdog = setTimeout(() => {
        this.firstFrameWatchdog = -1;
        if (this.isModelLoaded) {
          return;
        }
        DiagLog.note('[3d] newInit 后 15 秒没等到首帧，退回 2D');
        this.onFailure();
      }, 15000);
      return;
    }
    if (name === 'onFirstFrame' || name === 'onFullCarLoaded') {
      // 场景这时才建好，抠背景要等到这一刻。
      // onFullCarLoaded 时高精模型换过一轮，环境贴图要重烘一次。
      this.blendIntoBackground();
      this.cancelWatchdog();
      // 首帧一张、高精模型换上来后再一张，给服务卡片用。
      // 放在下面这句 `return` 前面：`onFullCarLoaded` 时 isModelLoaded 已经是 true，
      // 写在后面就只有首帧那张低精模型会被截走。
      this.scheduleSnapshot();
      if (this.isModelLoaded) {
        return;
      }
      this.isModelLoaded = true;
      this.onReady();
      this.replayLastState();
    }
  }

  private cancelWatchdog(): void {
    if (this.firstFrameWatchdog >= 0) {
      clearTimeout(this.firstFrameWatchdog);
      this.firstFrameWatchdog = -1;
    }
  }

  /**
   * 把渲染器自带的户外场景抠掉，只留车。
   *
   * 官方那套天空盒 + 雪地是给全屏爱车页做的，嵌到我们首页里就是两种视觉语气。
   * 但天空盒不能直接删——车漆的高光和镀铬件的反射全来自它。所以先把当前场景
   * 烘成一张环境贴图挂到 `scene.environment`，再隐藏天空盒和地面：
   * 反射还在，背景透出我们自己的界面。
   */
  private blendIntoBackground(): void {
    this.run(`
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
    `);
  }

  /**
   * 场景一建好就抠背景，别等首帧。
   *
   * 渲染器建好 `window.viewer` 到吐出第一帧之间有几十帧的空档，
   * 只在 `onFirstFrame` 里抠的话，用户会先看到一闪而过的雪地。
   * 所以从启动脚本开始就轮询，`viewer` 一出现立刻抠掉。
   */
  private startBlendWatcher(): void {
    this.run(`
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
    `);
  }

  // MARK: - 抓图

  /** 渲染完两秒后抓一张。延时是给动画留的：门窗、充电口盖都要放完才是定妆照。 */
  private scheduleSnapshot(): void {
    this.cancelSnapshot();
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = -1;
      this.captureSnapshot();
    }, 2000);
  }

  private cancelSnapshot(): void {
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }
  }

  /**
   * **不能截组件**：这块 Web 是透明的（`backgroundColor(Color.Transparent)`），
   * 而 WebGL 画布的内容不在组件的绘制树里——截出来是一整张空图。
   * iOS 上 `WKWebView.takeSnapshot` 也是同样的空，两端都验过。
   *
   * 所以让页面自己出图：同一个 JS 回合里先 `render` 再 `toDataURL`。
   * 顺序不能反——渲染器建 WebGL 上下文时没开 `preserveDrawingBuffer`，
   * 一出这个回合绘制缓冲就被清了，`toDataURL` 拿到的还是空图。
   */
  private captureSnapshot(): void {
    try {
      this.controller.runJavaScript(CarModel3DView.snapshotScript(CarModel3DView.snapshotMaxWidth))
        .then((result: string) => {
          const dataURL = CarModel3DView.unquote(result);
          if (dataURL.indexOf('data:image/png;base64,') !== 0) {
            DiagLog.note('[3d] 卡片车图没抓到');
            return;
          }
          this.onSnapshot(dataURL);
        })
        .catch((e: Error) => {
          DiagLog.note(`[3d] 卡片车图抓取失败：${e.message}`);
        });
    } catch (e) {
      DiagLog.note(`[3d] 卡片车图抓取失败：${e}`);
    }
  }

  /**
   * `runJavaScript` 交回来的是 **JSON 编码过**的返回值，字符串外面还套着一对引号。
   * base64 和 data URL 前缀里没有需要转义的字符，剥掉引号就够了。
   */
  private static unquote(result: string): string {
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      return result.substring(1, result.length - 1);
    }
    return result;
  }

  /**
   * 回传给卡片那张图的最大宽度。页面里先缩一道是为了别让一张几 MB 的 base64
   * 走一遍 JS 桥。落盘还会再缩到 480（见 `CarSnapshot`），这里留余量给裁边。
   */
  private static readonly snapshotMaxWidth: number = 960;

  /**
   * 抓图脚本。它依赖的全是渲染器内部结构（`window.viewer` 上的 renderer/scene/camera），
   * 改坏了编译器一句话都不会说，卡片上的车图会悄悄变空。
   */
  static snapshotScript(maxWidth: number): string {
    return `
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
        var scale = Math.min(1, ${maxWidth} / src.width);
        var out = document.createElement('canvas');
        out.width = Math.round(src.width * scale);
        out.height = Math.round(src.height * scale);
        try {
          out.getContext('2d').drawImage(src, 0, 0, out.width, out.height);
          return out.toDataURL('image/png');
        } catch (e) { return ''; }
      })();
    `;
  }

  // MARK: - 车况推送

  /**
   * 把车况映射成渲染器的命令数组。
   *
   * 命令协议来自渲染器自己的 `controller` 分发：
   * `[{ type: 'Door', command: [{ type: 'LeftFront_Door', open: true }] }, …]`
   */
  private push(): void {
    const state = this.state;
    if (state === null) {
      return;
    }
    const commands = CarModel3DView.commands(state);
    if (commands === this.lastPushed) {
      return;
    }
    this.lastPushed = commands;
    if (!this.isModelLoaded) {
      return;
    }
    this.run(`window.controller(${commands});`);
    // 门窗动画放完了才是卡片该看到的样子。
    this.scheduleSnapshot();
  }

  private replayLastState(): void {
    if (this.lastPushed.length === 0) {
      return;
    }
    this.run(`window.controller(${this.lastPushed});`);
  }

  static commands(state: VehicleState): string {
    const groups: string[] = [];

    // 读不到的门不发命令——不知道开没开，不等于关着。
    const doorCommands: string[] = [];
    CarModel3DView.appendBool(doorCommands, 'LeftFront_Door', state.bool(VehicleSignal.driverDoor));
    CarModel3DView.appendBool(doorCommands, 'RightFront_Door', state.bool(VehicleSignal.passengerDoor));
    CarModel3DView.appendBool(doorCommands, 'LeftRear_Door', state.bool(VehicleSignal.leftRearDoor));
    CarModel3DView.appendBool(doorCommands, 'RightRear_Door', state.bool(VehicleSignal.rightRearDoor));
    CarModel3DView.appendBool(doorCommands, 'Trunk', state.trunkOpen);
    if (doorCommands.length > 0) {
      groups.push(`{"type":"Door","command":[${doorCommands.join(',')}]}`);
    }

    const windowCommands: string[] = [];
    CarModel3DView.appendOpenness(windowCommands, 'LeftFront_Window', state.leftFrontWindow);
    CarModel3DView.appendOpenness(windowCommands, 'RightFront_Window', state.rightFrontWindow);
    CarModel3DView.appendOpenness(windowCommands, 'LeftRear_Window', state.leftRearWindow);
    CarModel3DView.appendOpenness(windowCommands, 'RightRear_Window', state.rightRearWindow);
    if (windowCommands.length > 0) {
      groups.push(`{"type":"Window","command":[${windowCommands.join(',')}]}`);
    }

    groups.push(`{"type":"Charge","command":[{"type":"Charge","open":${state.isCharging}}]}`);

    return `[${groups.join(',')}]`;
  }

  private static appendBool(into: string[], name: string, open: boolean | null): void {
    if (open === null) {
      return;
    }
    into.push(`{"type":"${name}","open":${open}}`);
  }

  private static appendOpenness(into: string[], name: string, openness: number | null): void {
    if (openness === null) {
      return;
    }
    into.push(`{"type":"${name}","open":${openness > 0}}`);
  }
}
