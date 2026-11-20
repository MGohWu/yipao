import { HdsNavDestination } from '@kit.UIDesignKit';
import { image } from '@kit.ImageKit';
import { vehicleStore, VehicleStore } from '../../app/VehicleStore';
import { DiagLog } from '../../core/DiagLog';
import { LeapError } from '../../core/LeapError';
import { LeapBackground } from '../../design/LeapGlass';
import { LeapMaterial } from '../../design/LeapMaterial';
import { LeapColors, LeapStyle } from '../../design/LeapStyle';
import { FeatureChrome, FeatureNote } from './FeatureScaffold';

/**
 * 驻车照片。对应 iOS 的 `ParkingPhotosPreviewView`。
 *
 * **真实链路**：`store.loadParkingPhoto()` 读服务端保存的最近一张，不会远程触发拍照。
 * 接口只有「最近一张」，没有历史列表。
 *
 * 拉不到就停在空态/错误态，**不塞示意图**——塞了就变成「App 说有照片」。
 */
@ComponentV2
export struct ParkingPhotosView {
  store: VehicleStore = vehicleStore;
  @Local isLoading: boolean = false;
  @Local photoImage: image.PixelMap | null = null;
  @Local uploadTime: string = '';
  @Local errorMessage: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    let source: image.ImageSource | null = null;
    try {
      const result = await this.store.loadParkingPhoto();
      this.uploadTime = result.photo.displayUploadTime ?? '';
      const data = result.data;
      if (data === null) {
        // 接口回了成功但没给地址：确实没有照片，不是出错。
        this.photoImage = null;
        return;
      }
      source = image.createImageSource(data);
      this.photoImage = await source.createPixelMap();
    } catch (e) {
      const message = LeapError.messageOf(e as object);
      DiagLog.note(`[parkingPhoto] 读取失败：${message}`);
      this.photoImage = null;
      this.uploadTime = '';
      this.errorMessage = message;
    } finally {
      if (source !== null) {
        // 解码完就放，`ImageSource` 拿着的是整张图的原始字节。
        source.release();
      }
      this.isLoading = false;
    }
  }

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.frostGlow })

        Scroll() {
          Column({ space: 18 }) {
            Column()
              .width('100%')
              .height(FeatureChrome.topInset)

            Column({ space: 10 }) {
              Row() {
                Text('最近驻车')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(LeapStyle.textPrimary)
                Blank()
                this.refreshButton()
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              this.photoContent()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            FeatureNote({
              symbol: $r('sys.symbol.hand_raised_hexagon_fill'),
              text: '照片由车辆驻车时自动记录。这里只读取服务端保存的最近一张，不会远程触发拍照。'
            })

            Column()
              .width('100%')
              .height(FeatureChrome.bottomInset)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(FeatureChrome.titleBar('驻车照片'))
  }

  @Builder
  refreshButton() {
    Stack() {
      if (this.isLoading) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(LeapStyle.textSecondary)
      } else {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(17)
          .fontColor([LeapStyle.textSecondary])
      }
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundEffect(LeapMaterial.cardEffect)
    .visualEffect(LeapMaterial.pressable)
    .onClick(() => {
      this.load();
    })
  }

  @Builder
  photoContent() {
    if (this.isLoading && this.photoImage === null) {
      Column({ space: 10 }) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(LeapStyle.textSecondary)
        Text('正在读取驻车照片')
          .fontSize(13)
          .fontColor(LeapStyle.textSecondary)
      }
      .width('100%')
      .constraintSize({ minHeight: 260 })
      .justifyContent(FlexAlign.Center)
      .borderRadius(LeapStyle.tileRadius)
      .backgroundEffect(LeapMaterial.cardEffect)
    } else if (this.photoImage !== null) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(this.photoImage)
          .objectFit(ImageFit.Contain)
          .width('100%')

        if (this.uploadTime.length > 0) {
          Text(this.uploadTime)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(LeapStyle.textPrimary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(6)
            .backgroundEffect(LeapMaterial.cardEffect)
            .margin(12)
        }
      }
      .width('100%')
      .borderRadius(LeapStyle.tileRadius)
      .clip(true)
    } else {
      this.emptyState()
    }
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      SymbolGlyph(this.errorMessage.length > 0
        ? $r('sys.symbol.exclamationmark_triangle')
        : $r('sys.symbol.camera_slash'))
        .fontSize(40)
        .fontColor([LeapStyle.textTertiary])
      Text(this.errorMessage.length > 0 ? '读取失败' : '暂无驻车照片')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.textPrimary)
      Text(this.errorMessage.length > 0
        ? this.errorMessage
        : '车辆可能尚未开启驻车拍照，稍后再试。')
        .fontSize(12)
        .fontColor(LeapStyle.textSecondary)
        .textAlign(TextAlign.Center)

      Text('重试')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(LeapStyle.accent)
        .padding({ left: 22, right: 22, top: 10, bottom: 10 })
        .borderRadius(20)
        .backgroundColor(LeapStyle.fillAccent)
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 260 })
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
    .borderRadius(LeapStyle.tileRadius)
    .backgroundEffect(LeapMaterial.cardEffect)
  }
}

// 「直进直出」页面 2026-11-19 随 iOS 一起下线：只删入口和页面，
// 蓝牙底层（`CallCarController`、`CallCarProtocol`、`BLEProtocol` 的直进直出帧）都留着，
// 想恢复把页面和功能页入口加回来即可。
