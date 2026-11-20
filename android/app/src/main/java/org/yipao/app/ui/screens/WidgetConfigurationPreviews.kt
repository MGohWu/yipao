package org.yipao.app.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DragIndicator
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.yipao.app.R
import org.yipao.app.app.VehicleStore
import org.yipao.app.core.CarImageCache
import org.yipao.app.core.SnapshotStore
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetButtonLayout
import org.yipao.app.core.WidgetSettings
import org.yipao.app.ui.theme.LeapColors
import org.yipao.app.widget.LeapSurfaces
import org.yipao.app.widget.WidgetActionAppearance
import org.yipao.app.widget.WidgetPalette
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private enum class PreviewSize(val title: String, val dimensions: String) {
    Small("小卡片", "2×2 · 2 个按钮"),
    Medium("中卡片", "4×2 · 中大共用 4 个按钮"),
    Large("大卡片", "4×4 · 中大共用 4 个按钮"),
}

private data class EditingWidgetSlot(val size: PreviewSize, val index: Int)

private class WidgetPreviewDragState {
    val bounds = mutableMapOf<WidgetAction, Rect>()
    var origin = Offset.Zero
    var action by mutableStateOf<WidgetAction?>(null)
    var position by mutableStateOf(Offset.Zero)
    var tileSize by mutableStateOf(Size.Zero)
    var onStart: (WidgetAction) -> Unit = {}
    var onDrop: (WidgetAction, WidgetAction) -> Unit = { _, _ -> }
    val target: WidgetAction? get() = bounds.entries.firstOrNull { it.value.contains(position) }?.key

    fun start(value: WidgetAction) {
        val rect = bounds[value] ?: return
        action = value
        position = rect.center
        tileSize = rect.size
        onStart(value)
    }

    fun move(amount: Offset) { position += amount }

    fun finish() {
        val from = action
        val to = target
        if (from != null && to != null && from != to) onDrop(from, to)
        cancel()
    }

    fun cancel() { action = null }
}

@Composable
internal fun WidgetPreviewConfiguration() {
    var smallButtons by remember { mutableStateOf(WidgetSettings.buttons(true)) }
    var buttons by remember { mutableStateOf(WidgetSettings.buttons(false)) }
    var editing by remember { mutableStateOf<EditingWidgetSlot?>(null) }
    val scope = rememberCoroutineScope()
    val store = VehicleStore.shared
    val snapshot = store.state?.let {
        VehicleSnapshot.make(it, store.vehicleName, store.locationName, store.lastUpdated ?: System.currentTimeMillis())
    } ?: remember { SnapshotStore.read() }
    val save: (EditingWidgetSlot, WidgetAction) -> Unit = { slot, action ->
        val small = slot.size == PreviewSize.Small
        val next = WidgetButtonLayout.replacing(if (small) smallButtons else buttons, slot.index, action)
        WidgetSettings.setButtons(small, next)
        if (small) smallButtons = next else buttons = next
        scope.launch { LeapSurfaces.reloadAll() }
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        PreviewSize.entries.forEach { size ->
            val actions = if (size == PreviewSize.Small) smallButtons else buttons
            val active = editing?.size == size
            val drag = remember(size) { WidgetPreviewDragState() }
            val bringIntoView = remember { BringIntoViewRequester() }
            val haptic = LocalHapticFeedback.current
            SideEffect {
                drag.bounds.keys.retainAll(actions.toSet())
                drag.onStart = { action ->
                    editing = EditingWidgetSlot(size, actions.indexOf(action))
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                }
                drag.onDrop = { from, to ->
                    val next = WidgetButtonLayout.moving(actions, actions.indexOf(from), actions.indexOf(to))
                    WidgetSettings.setButtons(size == PreviewSize.Small, next)
                    if (size == PreviewSize.Small) smallButtons = next else buttons = next
                    editing = EditingWidgetSlot(size, next.indexOf(from))
                    scope.launch { LeapSurfaces.reloadAll() }
                }
            }
            LaunchedEffect(active) {
                if (active && drag.action == null) bringIntoView.bringIntoView()
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth().bringIntoViewRequester(bringIntoView),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(size.title, style = MaterialTheme.typography.titleSmall)
                        Text(size.dimensions, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { editing = if (active) null else EditingWidgetSlot(size, 0) }) {
                        Icon(if (active) Icons.Outlined.Check else Icons.Outlined.Edit,
                            if (active) "完成配置" else "配置${size.title}按钮", modifier = Modifier.size(20.dp))
                    }
                }
                ConfigurableVehiclePreview(size, snapshot, actions, if (active) actions.getOrNull(editing?.index ?: 0) else null, if (active) drag else null) {
                    editing = EditingWidgetSlot(size, it)
                }
                if (active) {
                    WidgetActionPicker(actions[editing?.index ?: 0], snapshot) { action ->
                        editing?.let { save(it, action) }
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth()) {
            Text("独立控车卡片", style = MaterialTheme.typography.titleSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StandaloneWidgetPreview(WidgetAction.Lock, snapshot, Modifier.weight(1f))
                StandaloneWidgetPreview(WidgetAction.Unlock, snapshot, Modifier.weight(1f))
            }
        }
    }

}

@Composable
private fun WidgetActionPicker(selected: WidgetAction, snapshot: VehicleSnapshot?, onSelect: (WidgetAction) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 12.dp)) {
        Text("更换${selected.label}", style = MaterialTheme.typography.titleSmall)
        WidgetAction.entries.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                row.forEach { action ->
                    val chosen = action == selected
                    val appearance = WidgetActionAppearance.of(action, snapshot)
                    Box(
                        modifier = Modifier.weight(1f).height(78.dp).clip(RoundedCornerShape(8.dp))
                            .background(if (chosen) LeapColors.accent.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surfaceContainer)
                            .border(if (chosen) 2.dp else 1.dp, if (chosen) LeapColors.accent else MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(8.dp))
                            .clickable { onSelect(action) },
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                            modifier = Modifier.fillMaxSize()) {
                            Icon(painterResource(appearance.icon), null, modifier = Modifier.size(22.dp))
                            Text(action.label, style = MaterialTheme.typography.labelMedium, maxLines = 1)
                        }
                        if (chosen) Icon(Icons.Outlined.CheckCircle, "已选择", tint = LeapColors.accent,
                            modifier = Modifier.align(Alignment.TopEnd).padding(5.dp).size(16.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun ConfigurableVehiclePreview(
    size: PreviewSize, snapshot: VehicleSnapshot?, actions: List<WidgetAction>,
    selected: WidgetAction? = null, drag: WidgetPreviewDragState? = null, onEdit: (Int) -> Unit,
) {
    val context = LocalContext.current
    val shape = RoundedCornerShape(20.dp)
    val frame = if (size == PreviewSize.Small) Modifier.size(180.dp) else Modifier.fillMaxWidth().height(if (size == PreviewSize.Medium) 180.dp else 340.dp)
    Box(frame.clip(shape).background(WidgetPalette.background.getColor(context)).border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f), shape)
        .onGloballyPositioned { drag?.origin = it.positionInRoot() }
        .pointerInput(drag) {
            if (drag != null) detectDragGesturesAfterLongPress(
                onDragStart = { position -> drag.bounds.entries.firstOrNull { it.value.contains(position + drag.origin) }?.key?.let(drag::start) },
                onDrag = { change, amount -> if (drag.action != null) { change.consume(); drag.move(amount) } },
                onDragEnd = { drag.finish() }, onDragCancel = { drag.cancel() },
            )
        }) {
      Box(Modifier.fillMaxSize().padding(if (size == PreviewSize.Small) 12.dp else 16.dp)) {
        when (size) {
            PreviewSize.Small -> Column {
                PreviewVehicleName(snapshot)
                PreviewEnergy(snapshot, showFuel = true)
                Spacer(Modifier.weight(1f))
                PreviewActionRow(actions, snapshot, 44.dp, selected, drag, onEdit)
            }
            PreviewSize.Medium -> Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    PreviewVehicleName(snapshot)
                    Spacer(Modifier.weight(1f))
                    PreviewEnergy(snapshot, showFuel = true, medium = true)
                    if (snapshot?.isCharging == true) {
                        PreviewCaption(listOfNotNull(snapshot.chargeRemainingText, snapshot.chargePowerText).joinToString(" · "))
                    }
                    Spacer(Modifier.weight(1f))
                    PreviewCaption(snapshot?.headline ?: "暂无车况")
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    actions.chunked(2).forEachIndexed { row, pair ->
                        PreviewActionRow(pair, snapshot, 62.dp, selected, drag) { onEdit(row * 2 + it) }
                    }
                }
            }
            PreviewSize.Large -> Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { PreviewVehicleName(snapshot) }
                    PreviewCaption(snapshot?.lockText ?: "状态未知")
                }
                PreviewCar(Modifier.weight(1f).fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Box(Modifier.weight(1f)) { PreviewEnergy(snapshot, showFuel = false, large = true) }
                    snapshot?.gasolinePercent?.let { fuel ->
                        Column(Modifier.weight(1f)) {
                            PreviewReading(fuel, snapshot.fuelRangeKm, R.drawable.ic_widget_fuel)
                            PreviewBar(fuel)
                        }
                    }
                }
                if (snapshot?.isCharging == true) PreviewCaption(listOfNotNull(snapshot.chargeRemainingText, snapshot.chargePowerText).joinToString(" · "))
                Spacer(Modifier.height(14.dp))
                PreviewActionRow(actions, snapshot, 64.dp, selected, drag, onEdit)
            }
        }
      }
      if (drag?.action != null) {
          val density = LocalDensity.current
          val offset = drag.position - drag.origin - Offset(drag.tileSize.width / 2, drag.tileSize.height / 2)
          PreviewActionTile(drag.action!!, snapshot,
              with(density) { drag.tileSize.height.toDp() },
              Modifier.offset { IntOffset(offset.x.roundToInt(), offset.y.roundToInt()) }
                  .width(with(density) { drag.tileSize.width.toDp() }).scale(1.06f).shadow(8.dp, RoundedCornerShape(14.dp)),
              selected = true)
      }
    }
}

@Composable
private fun PreviewActionRow(actions: List<WidgetAction>, snapshot: VehicleSnapshot?, height: Dp,
    selected: WidgetAction?, drag: WidgetPreviewDragState?, onEdit: (Int) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.fillMaxWidth()) {
        actions.forEachIndexed { index, action ->
            PreviewActionTile(action, snapshot, height,
                Modifier.weight(1f).onGloballyPositioned { drag?.bounds?.set(action, it.boundsInRoot()) }
                    .alpha(if (drag?.action == action) 0.3f else 1f).clip(RoundedCornerShape(14.dp))
                    .clickable { onEdit(index) }.semantics { contentDescription = "更换${action.label}按钮" },
                selected = if (drag?.action != null) drag.target == action else selected == action,
                drag = drag)
        }
    }
}

@Composable
private fun PreviewActionTile(
    action: WidgetAction, snapshot: VehicleSnapshot?, height: Dp, modifier: Modifier,
    selected: Boolean = false, drag: WidgetPreviewDragState? = null,
) {
    val context = LocalContext.current
    val appearance = WidgetActionAppearance.of(action, snapshot)
    val foreground = WidgetPalette.tileForeground(appearance.tint, appearance.prominent).getColor(context)
    val shape = RoundedCornerShape(14.dp)
    Box(modifier.height(height).clip(shape)
        .background(WidgetPalette.tileFill(appearance.tint, appearance.prominent).getColor(context))
        .then(if (selected) Modifier.border(2.dp, LeapColors.accent, shape) else Modifier)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
            modifier = Modifier.fillMaxSize()) {
            Icon(painterResource(appearance.icon), null, tint = foreground, modifier = Modifier.size(17.dp))
            Text(appearance.title, color = foreground, fontSize = 10.sp, lineHeight = 12.sp,
                fontWeight = FontWeight.Medium, maxLines = 1)
        }
        if (drag != null) {
            Box(Modifier.align(Alignment.TopEnd).size(22.dp)
                .pointerInput(drag, action) {
                    detectDragGestures(onDragStart = { drag.start(action) },
                        onDrag = { change, amount -> change.consume(); drag.move(amount) },
                        onDragEnd = { drag.finish() }, onDragCancel = { drag.cancel() })
                }, contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.DragIndicator, "拖动${action.label}调整顺序", tint = foreground.copy(alpha = 0.65f), modifier = Modifier.size(12.dp))
            }
        }
    }
}

@Composable
private fun PreviewVehicleName(snapshot: VehicleSnapshot?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(snapshot?.vehicleName ?: "我的车", color = WidgetPalette.secondaryText.getColor(LocalContext.current), fontSize = 12.sp, lineHeight = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (snapshot?.isCharging == true) Icon(painterResource(R.drawable.ic_widget_bolt), "充电中", tint = LeapColors.accent, modifier = Modifier.size(11.dp))
    }
}

@Composable
private fun PreviewEnergy(snapshot: VehicleSnapshot?, showFuel: Boolean, large: Boolean = false, medium: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val splitRange = medium && snapshot?.hasFuel == true
        PreviewReading(snapshot?.soc, if (splitRange) null else if (large && snapshot?.gasolinePercent != null) snapshot.energyRangeKm else snapshot?.rangeKm, if (large) R.drawable.ic_widget_bolt else null)
        if (splitRange) snapshot?.mediumRangeText?.let { PreviewCaption(it) }
        PreviewBar(snapshot?.soc)
        if (showFuel) snapshot?.gasolinePercent?.let { fuel ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(painterResource(R.drawable.ic_widget_fuel), "油量", tint = WidgetPalette.tertiaryText.getColor(LocalContext.current), modifier = Modifier.size(9.dp))
                Box(Modifier.weight(1f)) { PreviewBar(fuel) }
            }
        }
    }
}

@Composable
private fun PreviewReading(percent: Int?, range: Int?, icon: Int?) {
    val context = LocalContext.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        if (icon != null) Icon(painterResource(icon), null, tint = WidgetPalette.tertiaryText.getColor(context), modifier = Modifier.size(10.dp))
        Text(percent?.toString() ?: "--", fontSize = 30.sp, lineHeight = 36.sp, fontWeight = FontWeight.Light, color = WidgetPalette.primaryText.getColor(context), modifier = Modifier.alignByBaseline())
        Text("%", fontSize = 13.sp, lineHeight = 16.sp, color = WidgetPalette.secondaryText.getColor(context), modifier = Modifier.alignByBaseline())
        Spacer(Modifier.weight(1f))
        if (range != null) Text("$range km", fontSize = 10.sp, lineHeight = 12.sp, color = WidgetPalette.secondaryText.getColor(context), maxLines = 1, modifier = Modifier.alignByBaseline())
    }
}

@Composable
private fun PreviewBar(percent: Int?) {
    val context = LocalContext.current
    Box(Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)).background(WidgetPalette.track.getColor(context))) {
        Box(Modifier.fillMaxWidth(((percent ?: 0) / 100f).coerceIn(0f, 1f)).fillMaxHeight().background(WidgetPalette.accent.getColor(context)))
    }
}

@Composable
private fun PreviewCaption(text: String) {
    Text(text, fontSize = 10.sp, lineHeight = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = WidgetPalette.secondaryText.getColor(LocalContext.current))
}

@Composable
private fun PreviewCar(modifier: Modifier = Modifier) {
    val car = remember { CarImageCache.shared() }
    Box(modifier, contentAlignment = Alignment.Center) {
        if (car != null) Image(car.asImageBitmap(), "车辆模型", contentScale = ContentScale.Fit, modifier = Modifier.fillMaxWidth(0.8f).fillMaxHeight(0.9f))
        else Icon(painterResource(R.drawable.ic_widget_car), "车辆模型", tint = WidgetPalette.tertiaryText.getColor(LocalContext.current), modifier = Modifier.size(56.dp))
    }
}

@Composable
private fun StandaloneWidgetPreview(action: WidgetAction, snapshot: VehicleSnapshot?, modifier: Modifier) {
    val context = LocalContext.current
    val tint = if (action == WidgetAction.Lock) LeapColors.accent else LeapColors.caution
    Column(modifier.aspectRatio(1f).clip(RoundedCornerShape(20.dp)).background(WidgetPalette.background.getColor(context)).padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(action.label, fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.SemiBold, color = WidgetPalette.primaryText.getColor(context), maxLines = 1, modifier = Modifier.weight(1f))
            Icon(painterResource(WidgetActionAppearance.of(action, snapshot).icon), null, tint = tint, modifier = Modifier.size(22.dp))
        }
        PreviewCaption(snapshot?.vehicleName ?: "我的车")
        PreviewCar(Modifier.weight(1f).fillMaxWidth())
        PreviewCaption(snapshot?.lockText ?: "状态未知")
    }
}
