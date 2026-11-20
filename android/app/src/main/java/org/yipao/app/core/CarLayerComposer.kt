package org.yipao.app.core

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.Shader
import java.io.File

/// 2D 车的分层贴图合成。
///
/// 没有 3D 的车型（S01、C10…）在 `carpicture/key/package` 里给的不是模型，
/// 而是一整套 1125×525 的图层：车身打底，门、引擎盖、尾门、充电各一层，
/// 官方爱车页就是把它们按车况叠出来的——所以那张图会跟着车动。
///
/// **叠加顺序不是猜的**，来自官方三处对照：
/// - `res/layout/lpcar_car_model.xml` —— RelativeLayout 子节点顺序就是 z 序
/// - `LPCarStateViewManager.OooO00o(state, iv1…iv15)` —— 谁在什么车况下显示、用哪张图
/// - `FragmentCarModelBinding` —— 把 iv1…iv15 和布局里的 view id 对上
///
/// 对上之后才发现两件容易叠错的事：**右侧的门和尾门画在车身下面**（那一侧本来
/// 就被车身挡住），以及**充电层的 z 位置按车型不同**（官方在布局里备了三个槽）。
///
/// 官方布局里还留着空调 ×3、轮毂、加热灯、行车灯六个 ImageView，但 1.22.87
/// 全 App 没有一行代码给它们 setImage——加密字符串表里连 `carpic_ac_*`、
/// `carpic_wheel*`、`carpic_frontrunning_*`、`carpic_heatlight_*` 都不存在。
/// 包里那些图是给别的版本备着的，我们也不叠，保持和官方一致。
object CarLayerComposer {

    /// 图层目录（解压后的 `android/xxhdpi`）。
    fun layerDirectory(root: File): File? {
        // 包里是 android/<density>/，密度目录名各车型可能不同，取第一个有 PNG 的。
        val densities = File(root, "android").listFiles() ?: return null
        return densities.firstOrNull { dir ->
            dir.isDirectory && dir.listFiles()?.any { it.name.endsWith(".png") } == true
        }
    }

    // MARK: - 车型分组

    /// 门窗规则的分组，对应 `CarStateViewController` 里的分支。
    ///
    /// 车型码取自 `CarDataUtil.sCarTypes`：s01 t03 a05 a10 b11 b10 b01 b05
    /// c01 c11 c10 c16 d19 d21 d99。注意官方 `isC10Car()` 把 `b11` 也算 c10。
    private enum class DoorRule {
        /// C11 和所有未列名车型：四门齐全，不补窗层，尾门恒显示。
        FullDoors,

        /// c10 / b11 / c01 / c16 / b10 / b01：四门齐全，门关时补一层窗。
        FullDoorsWithWindows,

        /// t03：同上，但尾门只在开着时画。
        T03,

        /// s01：两门轿跑，没有后门和后窗，尾门只在开着时画。
        S01;

        companion object {
            /// 前缀匹配，判据统一走 `CarTypeFamily`：carType 带上年款之类的后缀时，
            /// 精确匹配会让 `T03-2023` 静悄悄落进 `FullDoors`，按 C11 那套画门窗。
            /// 分支的先后顺序保持和官方 switch 一致。
            fun of(carType: String): DoorRule = when {
                CarTypeFamily.isS01(carType) -> S01
                CarTypeFamily.isT03(carType) -> T03
                CarTypeFamily.matches(carType, listOf("c10", "b11", "c01", "c16", "b10", "b01")) ->
                    FullDoorsWithWindows
                else -> FullDoors // c11 和其余车型走同一套
            }
        }
    }

    /// 充电层的 z 槽位。官方在布局里备了三个，按车型选一个用——
    /// 分组和门窗那套**不一样**（b01 门窗跟 c10，充电跟 c11）。
    private enum class ChargeSlot {
        /// `newchargingAnimate`：车身**下面**。c11 / c01 / b10 / b01 和未列名车型。
        BelowBody,

        /// `chargingAnimate`：车身上面、左后门下面。c16 / c10（含 b11）。
        AboveBody,

        /// `ivChargeAnimateOuter`：所有门之上。t03 / s01。
        AboveDoors;

        companion object {
            fun of(carType: String): ChargeSlot = when {
                CarTypeFamily.matches(carType, listOf("c16", "c10", "b11")) -> AboveBody
                CarTypeFamily.isLegacyFamily(carType) -> AboveDoors // t03 / s01
                else -> BelowBody
            }
        }
    }

    // MARK: - 图层方案

    /// 一次合成要用到的图层，按 z 序从下往上分三段。
    ///
    /// 中间那段是充电动画：0 张表示不画，1 张是静态图，多张按 [FRAME_INTERVAL_MS]
    /// 循环播放。分三段是因为充电层夹在中间——底和顶可以各合成一张静态图，
    /// 只有中间这段需要逐帧换。
    data class LayerPlan(
        val below: List<String> = emptyList(),
        val chargeFrames: List<String> = emptyList(),
        val above: List<String> = emptyList(),
    ) {
        val isAnimated: Boolean get() = chargeFrames.size > 1

        val signature: String
            get() = (below + "#" + chargeFrames + "#" + above).joinToString("|")
    }

    /// 官方帧间隔：`startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`。
    const val FRAME_INTERVAL_MS: Long = 110

    /// 按车况和车型排出图层方案。
    fun plan(state: VehicleState?, carType: String): LayerPlan {
        val doors = DoorRule.of(carType)
        val slot = ChargeSlot.of(carType)

        val below = mutableListOf<String>()
        val above = mutableListOf<String>()
        // 充电槽之前写 below、之后写 above，一次遍历就分好段。
        var reachedCharge = false
        fun put(name: String) {
            if (reachedCharge) above += name else below += name
        }

        val leftFrontOpen = state?.bool(VehicleSignal.DriverDoor) == true
        val rightFrontOpen = state?.bool(VehicleSignal.PassengerDoor) == true
        val leftRearOpen = state?.bool(VehicleSignal.LeftRearDoor) == true
        val rightRearOpen = state?.bool(VehicleSignal.RightRearDoor) == true
        // 官方这个字段叫 isTrunkLock，但用法是 `isTrunkLock ? tailgate_open : tailgate_close`，
        // 说的其实是尾门开着。
        val trunkOpen = state?.trunkOpen == true

        // ① 天幕。见 `skyLayerName` 的说明：判据我们拿不到，暂时不画。
        skyLayerName(state)?.let { put(it) }

        // ② 右前门。这一侧朝向观众的背面，官方把它画在车身下面。
        put(if (rightFrontOpen) "carpic_rightfront_open" else "carpic_rightfront_close")

        // ③ 右后门。两门轿跑没有。
        if (doors != DoorRule.S01) {
            put(if (rightRearOpen) "carpic_rightbehind_open" else "carpic_rightbehind_close")
        }

        // ④ 尾门。t03/s01 只在开着时画（包里也只有 open 那张），其余恒画。
        when (doors) {
            DoorRule.T03, DoorRule.S01 -> if (trunkOpen) put("carpic_tailgate_open")
            DoorRule.FullDoors, DoorRule.FullDoorsWithWindows ->
                put(if (trunkOpen) "carpic_tailgate_open" else "carpic_tailgate_close")
        }

        if (slot == ChargeSlot.BelowBody) reachedCharge = true

        // ⑤ 车身 + 引擎盖。引擎盖没有独立信号，官方也一律按关闭画。
        put("carpic_body")
        put("carpic_hood_close")

        // ⑥ 车窗补层。名字里的 close 说的是「门关着时那扇窗」——
        // 门开时用的是门的 open 图，里面自带窗，再叠这层会重影。
        // 所以它跟车窗开度无关，只看门。
        if (doors == DoorRule.FullDoorsWithWindows || doors == DoorRule.T03) {
            if (!leftFrontOpen) put("carpic_leftfront_window_close")
            if (!leftRearOpen) put("carpic_leftbehind_window_close")
        }

        if (slot == ChargeSlot.AboveBody) reachedCharge = true

        // ⑦ 左侧的门。这一侧朝向观众，画在车身上面。
        if (doors != DoorRule.S01) {
            put(if (leftRearOpen) "carpic_leftbehind_open" else "carpic_leftbehind_close")
        }
        put(if (leftFrontOpen) "carpic_leftfront_open" else "carpic_leftfront_close")

        if (slot == ChargeSlot.AboveDoors) reachedCharge = true

        // ⑧ 充电。行车中官方整层隐藏。
        val charge = if (state?.isDriving != true) chargeFrames(state, carType) else emptyList()

        // ⑨ 充电口盖。只有 t03/s01 画，且跟着充电层一起显示或隐藏。
        if (slot == ChargeSlot.AboveDoors && charge.isNotEmpty()) above += "carpic_charge_open"

        // ⑩ 车窗告警标签。同 ①，判据缺失。
        windowAlarmLayerName(state)?.let { above += it }

        return LayerPlan(below = below, chargeFrames = charge, above = above)
    }

    /// 充电层的帧。
    ///
    /// 官方 `startFileAnimDrawable(iv, "carpic_charge", n, 2, 110)`：从
    /// `carpic_charge2` 起连着取 n 张，每张 110ms 循环，缺哪张就在那停。
    /// n 按车型不同：s01 = 18、t03 = 14、其余 = 15。
    ///
    /// 不充电时按 `chargeState` 出一张静态图（`carpic_charge1` 是插枪待机、
    /// `carpic_charge2` 是充满）。
    private fun chargeFrames(state: VehicleState?, carType: String): List<String> =
        when (state?.chargeState) {
            1 -> {
                val count = when {
                    CarTypeFamily.isS01(carType) -> 18
                    CarTypeFamily.isT03(carType) -> 14
                    else -> 15
                }
                (0 until count).map { "carpic_charge${it + 2}" }
            }
            3, 4, 6 -> listOf("carpic_charge1")
            2 -> listOf("carpic_charge2")
            else -> emptyList()
        }

    /// 天幕状态标签（`carpic_windowstatus_top_green` / `_top_red`）。
    ///
    /// 官方判据是 `newSkystate` 加防盗状态 `isCarPrevent`，两个信号我们都没有，
    /// 而且这层是张写着中文的标签图、不是车体的一部分——首页那排徽章已经在播报
    /// 同样的事。等拿到信号再决定要不要接。
    @Suppress("UNUSED_PARAMETER")
    private fun skyLayerName(state: VehicleState?): String? = null

    /// 车窗告警标签（绿「车窗已开」/ 红「车窗未关」）。
    ///
    /// 绿红之分看的是钥匙位置 ON1（`isOn1Open`）——人在车上开窗是绿，熄火离车
    /// 还开着是红。这个信号我们读不到，猜错就是在车图上写一句错话，所以不画。
    @Suppress("UNUSED_PARAMETER")
    private fun windowAlarmLayerName(state: VehicleState?): String? = null

    // MARK: - 合成

    /// 叠好的车图。充电动画时 [chargeFrames] 有多张，界面逐帧切换。
    data class ComposedCar(
        /// 充电层以下（含车身）叠好的一张。
        val base: Bitmap,
        /// 充电层。空表示不画，一张是静态，多张循环播放。
        val chargeFrames: List<Bitmap> = emptyList(),
        /// 充电层以上（充电口盖等）叠好的一张，没有就是 null。
        val top: Bitmap? = null,
    ) {
        val isAnimated: Boolean get() = chargeFrames.size > 1

        /// 拍平成一张静态图，给小组件用。
        ///
        /// 小组件里播不了逐帧动画，也不该播——充电线一段段亮起来那套是首页的效果。
        /// 但充电层的**静态**那张（插枪待机 / 已充满）要留，不然插着枪的车在小组件上
        /// 看起来像没插。底/顶两段共用同一块画布，按同一个矩形画上去就自动对齐。
        fun still(): Bitmap {
            val out = Bitmap.createBitmap(base.width, base.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val rect = Rect(0, 0, base.width, base.height)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            canvas.drawBitmap(base, null, rect, paint)
            if (!isAnimated) chargeFrames.firstOrNull()?.let { canvas.drawBitmap(it, null, rect, paint) }
            top?.let { canvas.drawBitmap(it, null, rect, paint) }
            return out
        }
    }

    /// 把图层按方案叠出来。缺失的图层跳过；车身那张都读不到返回 null。
    fun compose(state: VehicleState?, carType: String, layerDirectory: File): ComposedCar? {
        // 画布尺寸一律以车身那张为准。分层图**不保证同尺寸**——同一个包里行车灯就是
        // 1125×1200 而车身是 1125×525。而且底/顶两段是分开渲染的，画布不统一的话
        // 它们各自等比缩放之后会对不齐，车图两侧会多出一圈边。
        val body = load("carpic_body", layerDirectory) ?: return null
        val canvasWidth = body.width
        val canvasHeight = body.height
        val plan = plan(state, carType)
        val base = flatten(plan.below, layerDirectory, canvasWidth, canvasHeight) ?: return null
        return ComposedCar(
            // 充电层不用羽化：它画的是车身中部的充电线，够不着画布边缘，
            // 而它有 14–18 帧，每帧都重绘一遍纯属白给。
            base = feathered(base),
            chargeFrames = plan.chargeFrames.mapNotNull { name ->
                load(name, layerDirectory)?.let { fit(it, canvasWidth, canvasHeight) }
            },
            top = flatten(plan.above, layerDirectory, canvasWidth, canvasHeight)?.let { feathered(it) },
        )
    }

    // MARK: - 边缘羽化

    /// 羽化区占画布对应边长的比例。
    ///
    /// 官方图层在画布左右边缘留了**不透明的环境像素**，而且不同车型留的还不是
    /// 一种东西——实测两台 C11：
    /// - 白色那台：接地阴影是一条横贯全宽的暗带，铺到画布边缘时还有约 10% 不透明度，
    ///   然后被画布一刀切断，在地面高度留下两条竖直硬边；
    /// - 黑色那台：左右各一条纯白柔光柱，外缘 255 向内线性衰减到 0，跨度正好 10% 图宽。
    ///
    /// 官方爱车页底色是浅灰，这些东西全藏在背景里；我们的背景是渐变蓝/深色，它们
    /// 就成了两道扎眼的竖边。没法逐车型枚举，统一按比例羽化掉最外一圈。
    ///
    /// 10% 是量出来的：白柱正好这么宽，而车体离画布边缘还有 16% 以上（白车 17%、
    /// 黑车 16%），羽化吃不到车。真要有车型把车画得更靠边，宁可车头淡一点，
    /// 也好过挂两根柱子。
    private const val FEATHER_RATIO = 0.1f

    /// 把图的四边按 [FEATHER_RATIO] 渐隐到全透明。
    ///
    /// 早先只处理左右两侧；S01 的接地阴影还会一直铺到画布底边，小组件裁切后就
    /// 露出一条矩形横边。上下也套同样的 smoothstep 遮罩，车身本体离边缘足够远，
    /// 被消掉的只有环境光和接地阴影的截断部分。
    ///
    /// 就地改这张位图而不是再开一张：这些图 1125×525 起步，多一份就是 2MB 起，
    /// 而 `flatten` 出来的那张本来就是我们自己新建的，没有别人在引用。
    private fun feathered(image: Bitmap): Bitmap {
        if (image.width <= 0 || image.height <= 0) return image
        val canvas = Canvas(image)
        val paint = Paint()
        // DST_IN：只保留渐变里 alpha 不为 0 的部分，等价于给图套一层遮罩。
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
        paint.shader = featherShader(image.width.toFloat(), vertical = false)
        canvas.drawRect(0f, 0f, image.width.toFloat(), image.height.toFloat(), paint)
        paint.shader = featherShader(image.height.toFloat(), vertical = true)
        canvas.drawRect(0f, 0f, image.width.toFloat(), image.height.toFloat(), paint)
        return image
    }

    /// 两端渐隐、中间全实的遮罩渐变。
    ///
    /// 用 smoothstep 采样而不是直线：线性渐隐在羽化区内侧会留下一道能看出来的
    /// 折线（斜率突变），smoothstep 两端斜率为 0，接得上。
    private fun featherShader(length: Float, vertical: Boolean): Shader {
        val steps = 8
        val stops = mutableListOf<Pair<Float, Int>>()
        for (i in 0..steps) {
            val t = i.toFloat() / steps
            val alpha = t * t * (3 - 2 * t) // smoothstep
            // 左侧升、右侧降，中间那段保持全实。
            stops += (t * FEATHER_RATIO) to color(alpha)
            stops += (1 - FEATHER_RATIO + t * FEATHER_RATIO) to color(1 - alpha)
        }
        // 上面是左右交替追加的，得按位置排回去。
        val sorted = stops.sortedBy { it.first }
        return LinearGradient(
            0f,
            0f,
            if (vertical) 0f else length,
            if (vertical) length else 0f,
            sorted.map { it.second }.toIntArray(),
            sorted.map { it.first }.toFloatArray(),
            Shader.TileMode.CLAMP,
        )
    }

    private fun color(alpha: Float): Int {
        val a = (alpha.coerceIn(0f, 1f) * 255).toInt()
        return (a shl 24) or 0x00FFFFFF
    }

    // MARK: - 位图工具

    private fun load(name: String, directory: File): Bitmap? {
        val file = File(directory, "$name.png")
        if (!file.exists()) return null
        // inScaled 关掉：图本身就是按像素算好的，别让 BitmapFactory 再按屏幕密度缩一道。
        val options = BitmapFactory.Options().apply { inScaled = false }
        return runCatching { BitmapFactory.decodeFile(file.path, options) }.getOrNull()
    }

    private fun flatten(names: List<String>, directory: File, width: Int, height: Int): Bitmap? {
        val images = names.mapNotNull { load(it, directory) }
        if (images.isEmpty()) return null
        return draw(images, width, height)
    }

    /// 尺寸已经对得上就原样用，省一次重绘。
    private fun fit(image: Bitmap, width: Int, height: Int): Bitmap =
        if (image.width == width && image.height == height) image
        else draw(listOf(image), width, height) ?: image

    private fun draw(images: List<Bitmap>, width: Int, height: Int): Bitmap? {
        if (width <= 0 || height <= 0) return null
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val rect = Rect(0, 0, width, height)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        for (image in images) canvas.drawBitmap(image, null, rect, paint)
        return out
    }
}
