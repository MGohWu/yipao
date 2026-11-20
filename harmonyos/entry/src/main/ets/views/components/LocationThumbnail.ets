import { staticMap, mapCommon } from '@kit.MapKit';
import { image } from '@kit.ImageKit';
import { Coordinate } from '../../core/LeapModels';
import { LeapStyle } from '../../design/LeapStyle';
import { DiagLog } from '../../core/DiagLog';
import { LeapError } from '../../core/LeapError';

/**
 * 首页的地图缩略图。不可交互，点整张卡片进详情页。
 *
 * 用华为地图的静态图（`staticMap.getMapImage`）而不是完整的 `MapComponent`：
 * 首页这块只有 104 高，起一个可交互地图既费电又会抢走列表的滑动手势。
 * 这也是卡片上那张缩略图的同一条路——两边取图规则一致，不会一张新一张旧。
 *
 * 注意：华为地图要在 AGC 里配好本应用的 client_id 且签名指纹匹配才会出图，
 * 没配好时接口不报错，只是拿不到图，这里退回占位块。
 */
@ComponentV2
export struct LocationThumbnail {
  @Param coordinate: Coordinate | null = null;
  @Local mapImage: image.PixelMap | null = null;
  /** 上一次取图用的坐标，车没动就不重复取。 */
  private lastKey: string = '';

  aboutToAppear(): void {
    this.loadMap();
  }

  @Monitor('coordinate')
  onCoordinateChanged(): void {
    this.loadMap();
  }

  private async loadMap(): Promise<void> {
    const coordinate = this.coordinate;
    if (coordinate === null) {
      this.mapImage = null;
      this.lastKey = '';
      return;
    }
    const key = `${coordinate.latitude.toFixed(5)},${coordinate.longitude.toFixed(5)}`;
    if (key === this.lastKey) {
      return;
    }
    this.lastKey = key;
    try {
      const options: staticMap.StaticMapOptions = {
        location: { latitude: coordinate.latitude, longitude: coordinate.longitude },
        zoom: 16,
        imageWidth: 720,
        imageHeight: 300,
        scale: 1,
        // 车的位置用默认标记，图上有个明确的落点，用户一眼知道车在哪。
        markers: [{ location: { latitude: coordinate.latitude, longitude: coordinate.longitude } }],
        dayNightMode: mapCommon.DayNightMode.AUTO
      };
      this.mapImage = await staticMap.getMapImage(options);
    } catch (e) {
      // 取不到就留占位块，不打扰用户——但原因要留在日志里，
      // 否则「地图是白的」这种反馈永远查不下去。
      DiagLog.note(`[map] 静态图失败：${LeapError.messageOf(e as object)}`);
      this.mapImage = null;
    }
  }

  build() {
    Stack() {
      if (this.mapImage !== null) {
        Image(this.mapImage)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(LeapStyle.separator)
        SymbolGlyph($r('sys.symbol.map_slash'))
          .fontSize(20)
          .fontColor([LeapStyle.textTertiary])
      }
    }
    .width('100%')
    .height('100%')
    // 缩略图不接手势，整张卡片才是可点区域。
    .hitTestBehavior(HitTestMode.None)
  }
}
