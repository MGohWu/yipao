import { HdsNavDestination } from '@kit.UIDesignKit';
import { LeapBackground } from '../design/LeapGlass';
import { LeapMaterial } from '../design/LeapMaterial';
import { LeapColors } from '../design/LeapStyle';
import { MileageStatsContent } from './MileageStatsView';
import { PageMetrics } from './components/PageHeader';

/**
 * 行程页。与 iOS 的 `TripsView.swift` 同源。
 *
 * 内容是零跑官方按天统计的里程能耗。
 */
@ComponentV2
export struct TripsView {
  @Param onPush: (route: string) => void = (route: string) => {
  };

  build() {
    HdsNavDestination() {
      Stack() {
        LeapBackground({ tint: LeapColors.accentGlow })
        Column() {
          Column()
            .width('100%')
            .height(PageMetrics.navTopInset)
          MileageStatsContent()
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: LeapMaterial.navigationTitleBarStyle(),
      content: { title: { mainTitle: '行程' } },
      avoidLayoutSafeArea: true
    })
  }
}
