import { image } from '@kit.ImageKit';
import { drawing, common2D } from '@kit.ArkGraphics2D';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { LayerPlan } from '../core/CarLayerComposer';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

/**
 * 给 4×4 服务卡片预渲染的车图。
 *
 * 首页那张车是 `Stack` 里几张 `Image` 现叠出来的（见 VehicleHero），卡片这边不行：
 * 卡片进程读不到应用沙箱，图片只能通过 Form Kit 的 `formImages` 递文件描述符过去，
 * 一层一个 fd 的话既要开七八个描述符，卡片那头还得当场解七八张 1125×525 的大图——
 * 卡片进程的内存预算撑不住。所以在主应用这边拍平成一张、缩到卡片用得上的尺寸再落盘，
 * 和 iOS 的 `CarImageCache.storeShared` 是同一套做法。
 *
 * 拍平的口径也和 iOS 一致：底层 + **静态**充电层 + 顶层。卡片播不了逐帧动画，
 * 但插枪待机 / 已充满那张要留，否则插着枪的车在卡片上看起来像没插。
 */
export class CarSnapshot {
  private static readonly fileName = 'card-car.png';
  /**
   * 落盘宽度。官方图层是 1125 宽的宽幅画布，原样存下来卡片每次渲染都要解一张
   * 几百 KB 的大图，而它在卡片上最宽也就铺满一行。
   */
  private static readonly outputWidth = 480;
  private static path: string = '';
  /** 上一次出图用的图层方案。车况没变就不重叠——一次要解七八张 PNG。 */
  private static lastSignature: string = '';

  static init(context: common.Context): void {
    CarSnapshot.path = `${context.filesDir}/${CarSnapshot.fileName}`;
  }

  /** 已经出好的图在哪。没有就是空串。 */
  static get filePath(): string {
    if (CarSnapshot.path.length === 0) {
      return '';
    }
    try {
      return fileIo.accessSync(CarSnapshot.path) ? CarSnapshot.path : '';
    } catch (e) {
      return '';
    }
  }

  /** 按当前图层方案出一张图并落盘。成功返回路径，失败返回空串。 */
  static async render(layerDirectory: string, plan: LayerPlan): Promise<string> {
    if (CarSnapshot.path.length === 0 || layerDirectory.length === 0 || plan.isEmpty) {
      return '';
    }
    // 签名带上图层目录（按 VIN 分的）：两台车都锁着不充电时图层名一模一样，
    // 只比图层名的话换车之后会因「没变化」直接返回，卡片上挂的还是上一台车。
    const signature = `${layerDirectory}#${plan.signature}`;
    if (signature === CarSnapshot.lastSignature && CarSnapshot.filePath.length > 0) {
      return CarSnapshot.path;
    }
    const names: string[] = [];
    for (let i = 0; i < plan.below.length; i++) {
      names.push(plan.below[i]);
    }
    if (!plan.isAnimated && plan.chargeFrames.length > 0) {
      names.push(plan.chargeFrames[0]);
    }
    for (let i = 0; i < plan.above.length; i++) {
      names.push(plan.above[i]);
    }
    try {
      const flattened = await CarSnapshot.flatten(layerDirectory, names);
      if (flattened === null) {
        return '';
      }
      await CarSnapshot.write(flattened);
      CarSnapshot.lastSignature = signature;
      return CarSnapshot.path;
    } catch (e) {
      DiagLog.note(`[card] 车图合成失败：${LeapError.messageOf(e as object)}`);
      return '';
    }
  }

  /**
   * 3D 渲染器截来的那张，直接顶替叠图。
   *
   * 3D 车的资源包里根本没有 2D 图层（真机实测：C11 2026 解出来只有渲染器和模型，
   * 没有 `android/<density>/`），`render()` 那条路一次都跑不了——`layerDirectory`
   * 是空串，第一句就返回了。卡片上的车图因此一直是空的，桌面上只剩剪影。
   * 官方也是这么绕过去的：3D 车的爱车图就是渲染器截的图，2D 车才是分层贴图叠的。
   *
   * 两条路写的是同一个文件，但不会打架：一台车只会是其中一种。
   */
  static async adoptRendered(dataURL: string): Promise<string> {
    const marker = 'base64,';
    const at = dataURL.indexOf(marker);
    if (CarSnapshot.path.length === 0 || at < 0) {
      return '';
    }
    let pixelMap: image.PixelMap | null = null;
    try {
      const bytes = new util.Base64Helper().decodeSync(dataURL.substring(at + marker.length));
      const source = image.createImageSource(bytes.buffer as ArrayBuffer);
      try {
        pixelMap = await source.createPixelMap({ editable: true });
      } finally {
        source.release();
      }
      const size = (await pixelMap.getImageInfo()).size;
      // 背景没抠干净的那种整块底图会被挡在这一步：整张不透明时外接矩形正好等于
      // 画布本身，`requireTransparentBorder` 就是冲它去的。写不进去保持原样，
      // 卡片上留着剪影也比糊一整块底色强。
      if (!await CarSnapshot.trim(pixelMap, size, true)) {
        pixelMap.release();
        return '';
      }
      const cropped = (await pixelMap.getImageInfo()).size;
      const ratio = CarSnapshot.outputWidth / cropped.width;
      if (ratio < 1) {
        await pixelMap.scale(ratio, ratio);
      }
      // write() 里会 release，这里交出去之后不再碰它。
      await CarSnapshot.write(pixelMap);
      // 叠图那条路的去重签名要作废：万一之后这台车又走回叠图，
      // 签名还留着的话会以为「没变化」，卡片上挂的还是这张截图。
      CarSnapshot.lastSignature = '';
      return CarSnapshot.path;
    } catch (e) {
      if (pixelMap !== null) {
        pixelMap.release();
      }
      DiagLog.note(`[card] 渲染截图落盘失败：${LeapError.messageOf(e as object)}`);
      return '';
    }
  }

  /**
   * 换车、退出登录、关掉「显示车模型」时把图删掉，卡片当场退回剪影。
   * 不删的话桌面上会一直挂着上一台车（或上一位用户的车）。
   */
  static clear(): void {
    CarSnapshot.lastSignature = '';
    if (CarSnapshot.path.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(CarSnapshot.path);
    } catch (e) {
      // 本来就没有图是正常情况。
    }
  }

  /**
   * 按 z 序把图层叠成一张。
   *
   * 画布尺寸一律以车身那张为准：分层图**不保证同尺寸**，同一个包里行车灯是
   * 1125×1200 而车身是 1125×525。尺寸不一样的层按等比缩放居中画进画布，
   * 直接拉伸的话车灯会横着抻宽，落在车身上就是错位的一片。
   */
  private static async flatten(directory: string, names: string[]): Promise<image.PixelMap | null> {
    const size = await CarSnapshot.canvasSize(directory);
    if (size === null) {
      return null;
    }
    // 全 0 的缓冲区就是一张全透明画布。图层自己带透明背景，底不能是黑的。
    const canvasMap = await image.createPixelMap(new ArrayBuffer(size.width * size.height * 4), {
      size: size,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    });
    const canvas = new drawing.Canvas(canvasMap);
    let drawn = 0;
    for (let i = 0; i < names.length; i++) {
      // 包里缺哪张就跳过——官方的图层包并不保证每个车型都齐全，
      // 和 `CarLayerComposer.paths` 一个口径。
      const layer = await CarSnapshot.decode(`${directory}/${names[i]}.png`);
      if (layer === null) {
        continue;
      }
      try {
        const info = await layer.getImageInfo();
        if (info.size.width === size.width && info.size.height === size.height) {
          canvas.drawImage(layer, 0, 0);
        } else {
          canvas.drawImageRect(layer, CarSnapshot.fitted(info.size, size));
        }
        drawn++;
      } finally {
        layer.release();
      }
    }
    if (drawn === 0) {
      canvasMap.release();
      return null;
    }
    CarSnapshot.feather(canvas, size);
    if (!await CarSnapshot.trim(canvasMap, size)) {
      canvasMap.release();
      return null;
    }
    const cropped = (await canvasMap.getImageInfo()).size;
    const ratio = CarSnapshot.outputWidth / cropped.width;
    if (ratio < 1) {
      await canvasMap.scale(ratio, ratio);
    }
    return canvasMap;
  }

  /**
   * 羽化区宽度占画布宽度的比例。
   *
   * 官方图层在画布左右边缘留了**不透明的环境像素**，而且不同车型留的还不是一种东西
   * （实测两台 C11：一台是横贯全宽的接地阴影暗带，一台是左右各一条纯白柔光柱）。
   * 官方爱车页底色是浅灰，这些东西全藏在背景里；卡片上就是两道扎眼的竖边，
   * 而且它们撑着「内容外接矩形」，下面那道裁边等于白做。
   *
   * 10% 是 iOS / 安卓两端量出来的同一个值：白柱正好这么宽，而车体离画布边缘还有
   * 16% 以上，羽化吃不到车。
   */
  private static readonly featherRatio = 0.1;

  /** 把画布左右两侧按 `featherRatio` 渐隐到全透明。上下边缘官方图留了足够留白，没见过被切的。 */
  private static feather(canvas: drawing.Canvas, size: image.Size): void {
    const brush = new drawing.Brush();
    // DST_IN：只拿这一笔的 alpha 去乘画布，颜色不参与，等于给画布刷一层透明度蒙版。
    brush.setBlendMode(drawing.BlendMode.DST_IN);
    brush.setShaderEffect(drawing.ShaderEffect.createLinearGradient(
      { x: 0, y: 0 }, { x: size.width, y: 0 },
      [0x00000000, 0xFF000000, 0xFF000000, 0x00000000],
      drawing.TileMode.CLAMP,
      [0, CarSnapshot.featherRatio, 1 - CarSnapshot.featherRatio, 1]
    ));
    canvas.attachBrush(brush);
    canvas.drawRect({ left: 0, top: 0, right: size.width, bottom: size.height });
    canvas.detachBrush();
  }

  /** 低于这个 alpha 的像素当成透明。羽化带的外缘不是纯 0，纯 0 的判据会把它整条留下来。 */
  private static readonly alphaFloor = 8;

  /**
   * 按 alpha 求出内容的外接矩形，就地裁掉四周的透明边。全透明时返回 false——
   * 宁可让卡片退回剪影，也别写一张空图上去。
   *
   * 官方图层是 1125×525 的宽幅画布，车只占中间一条。不裁的话车在卡片那块
   * 124 高的位置上会缩成中间细细一道。
   */
  private static async trim(pixelMap: image.PixelMap, size: image.Size,
    requireTransparentBorder: boolean = false): Promise<boolean> {
    const buffer = new ArrayBuffer(size.width * size.height * 4);
    await pixelMap.readPixelsToBuffer(buffer);
    const pixels = new Uint8Array(buffer);
    let minX = size.width;
    let minY = size.height;
    let maxX = -1;
    let maxY = -1;
    for (let y = 0; y < size.height; y++) {
      const row = y * size.width * 4;
      for (let x = 0; x < size.width; x++) {
        // RGBA_8888，alpha 是每像素第四个字节。
        if (pixels[row + x * 4 + 3] <= CarSnapshot.alphaFloor) {
          continue;
        }
        if (x < minX) {
          minX = x;
        }
        if (x > maxX) {
          maxX = x;
        }
        if (y < minY) {
          minY = y;
        }
        if (y > maxY) {
          maxY = y;
        }
      }
    }
    if (maxX < minX || maxY < minY) {
      return false;
    }
    // 四周一圈都是实的，说明这张图压根没有透明背景。
    if (requireTransparentBorder &&
      (minX === 0 || minY === 0 || maxX === size.width - 1 || maxY === size.height - 1)) {
      return false;
    }
    await pixelMap.crop({
      x: minX, y: minY,
      size: { width: maxX - minX + 1, height: maxY - minY + 1 }
    });
    return true;
  }

  /** 车身那张的尺寸。它是必需的：连车身都读不到就没有车可画。 */
  private static async canvasSize(directory: string): Promise<image.Size | null> {
    const body = await CarSnapshot.decode(`${directory}/carpic_body.png`);
    if (body === null) {
      return null;
    }
    try {
      return (await body.getImageInfo()).size;
    } finally {
      body.release();
    }
  }

  /** 等比缩放后居中的目标矩形。 */
  private static fitted(source: image.Size, canvas: image.Size): common2D.Rect {
    const scale = Math.min(canvas.width / source.width, canvas.height / source.height);
    const width = source.width * scale;
    const height = source.height * scale;
    const left = (canvas.width - width) / 2;
    const top = (canvas.height - height) / 2;
    return { left: left, top: top, right: left + width, bottom: top + height };
  }

  private static async decode(file: string): Promise<image.PixelMap | null> {
    try {
      if (!fileIo.accessSync(file)) {
        return null;
      }
      const source = image.createImageSource(file);
      try {
        return await source.createPixelMap({ editable: true });
      } finally {
        source.release();
      }
    } catch (e) {
      return null;
    }
  }

  private static async write(pixelMap: image.PixelMap): Promise<void> {
    const packer = image.createImagePacker();
    try {
      const buffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
      // 覆盖写：TRUNC 不加的话，新图比旧图短时尾部会留着上一张的字节，PNG 直接解不出来。
      const file = fileIo.openSync(CarSnapshot.path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
    } finally {
      packer.release();
      pixelMap.release();
    }
  }
}
