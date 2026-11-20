package org.yipao.app.widget

import org.yipao.app.R
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction

// Compose 配置预览与 Glance 桌面卡片共用动作外观，点击行为由各自的宿主提供。
internal data class WidgetActionAppearance(
    val icon: Int,
    val title: String,
    val tint: WidgetTint,
    val prominent: Boolean,
) {
    companion object {
        fun of(action: WidgetAction, snapshot: VehicleSnapshot?): WidgetActionAppearance = when (action) {
            WidgetAction.ToggleLock -> WidgetActionAppearance(
                lockIcon(snapshot?.isLocked), snapshot?.lockText ?: "状态未知", lockTint(snapshot?.isLocked), true,
            )
            WidgetAction.Lock -> WidgetActionAppearance(R.drawable.ic_widget_lock, action.label, WidgetTint.Accent, true)
            WidgetAction.Unlock -> WidgetActionAppearance(R.drawable.ic_widget_lock_open, action.label, WidgetTint.Caution, true)
            WidgetAction.ToggleClimate -> WidgetActionAppearance(
                R.drawable.ic_widget_climate, "空调", WidgetTint.Cool, snapshot?.climateOn == true,
            )
            WidgetAction.Trunk -> WidgetActionAppearance(
                R.drawable.ic_widget_trunk, "尾门",
                if (snapshot?.trunkOpen == true) WidgetTint.Caution else WidgetTint.Cool, snapshot?.trunkOpen == true,
            )
            WidgetAction.Horn -> WidgetActionAppearance(R.drawable.ic_widget_horn, "鸣笛", WidgetTint.Cool, false)
        }
    }
}
