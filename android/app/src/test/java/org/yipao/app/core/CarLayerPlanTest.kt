package org.yipao.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// 官方 2D 分层贴图的层序与选层规则。
///
/// 为什么要钉在单测里：这套顺序抄自官方三处互相印证的产物（`lpcar_car_model.xml` 的
/// 层序、`LPCarStateViewManager` 给 iv1…iv15 派图层的分支、`FragmentCarModelBinding`），
/// 而错了不会有任何报错——只是车图上多一扇重影的门、或者充电动画跑到车身背面去了。
/// 界面上一眼看不出来，得对着官方 App 逐帧比。
///
/// 两条最容易写反的规则单独列了用例：**右侧门和尾门画在车身下面**，
/// **充电层的槽位按车型变**（b01 的门窗跟 c10、充电跟 c11，两套分组不是一套）。
class CarLayerPlanTest {

    /// 按 schema 自己的候选 key 造车况，免得测试里硬写 `"3204"` 这种数字 ID——
    /// 内置表哪天换了候选顺序，硬写的那份会静悄悄失配、所有断言都按「读不到」过。
    private fun state(
        schema: SignalSchema,
        vararg pairs: Pair<VehicleSignal, String>,
    ): VehicleState = VehicleState(
        signalMap = pairs.associate { (signal, value) -> schema.candidates(signal).first() to value },
        schema = schema,
    )

    private fun c11(vararg pairs: Pair<VehicleSignal, String>) = state(SignalSchema.numeric, *pairs)

    private fun s01(vararg pairs: Pair<VehicleSignal, String>) = state(SignalSchema.legacy, *pairs)

    /// 从下往上的完整层序。分段只是为了让充电层能单独逐帧换，`below` 永远在 `above` 之下，
    /// 所以问「谁画在谁上面」时把两段接起来看就行。
    private val CarLayerComposer.LayerPlan.stack: List<String> get() = below + above

    // MARK: - 层序

    @Test
    fun `右侧门和尾门画在车身下面`() {
        // 最容易写反的一条：朝向观众背面的那一侧，官方把它压在车身之下。
        val stack = CarLayerComposer.plan(c11(), "C11").stack
        val body = stack.indexOf("carpic_body")
        assertTrue("层序里应该有车身", body >= 0)
        assertTrue(stack.indexOf("carpic_rightfront_close") < body)
        assertTrue(stack.indexOf("carpic_rightbehind_close") < body)
        assertTrue(stack.indexOf("carpic_tailgate_close") < body)
    }

    @Test
    fun `左侧门画在车身上面`() {
        val stack = CarLayerComposer.plan(c11(), "C11").stack
        val body = stack.indexOf("carpic_body")
        assertTrue(stack.indexOf("carpic_leftbehind_close") > body)
        assertTrue(stack.indexOf("carpic_leftfront_close") > body)
        // 左前门是最靠观众的那一层，整摞的最后一张。
        assertEquals("carpic_leftfront_close", stack.last())
    }

    @Test
    fun `开着的门换成 open 那张`() {
        val stack = CarLayerComposer.plan(
            c11(
                VehicleSignal.DriverDoor to "1",
                VehicleSignal.RightRearDoor to "1",
                VehicleSignal.TrunkOpen to "1",
            ),
            "C11",
        ).stack
        assertTrue(stack.contains("carpic_leftfront_open"))
        assertTrue(stack.contains("carpic_rightbehind_open"))
        assertTrue(stack.contains("carpic_tailgate_open"))
        // 同一扇门不能同时出两张，否则会重影。
        assertFalse(stack.contains("carpic_leftfront_close"))
        assertFalse(stack.contains("carpic_rightbehind_close"))
        assertFalse(stack.contains("carpic_tailgate_close"))
    }

    // MARK: - 车型分组：门窗

    @Test
    fun `S01 没有后门和后窗`() {
        assertTrue(CarLayerComposer.plan(s01(), "S01").stack.none { it.contains("behind") })
    }

    @Test
    fun `S01 和 T03 的尾门只在开着时画`() {
        for (carType in listOf("S01", "T03")) {
            val closed = CarLayerComposer.plan(s01(), carType).stack
            assertTrue("$carType 关着时不该有尾门层", closed.none { it.contains("tailgate") })
            val open = CarLayerComposer.plan(s01(VehicleSignal.TrunkOpen to "1"), carType).stack
            assertTrue("$carType 开着时要有尾门层", open.contains("carpic_tailgate_open"))
        }
    }

    @Test
    fun `补窗层只给 c10 那批和 T03`() {
        assertTrue(CarLayerComposer.plan(c11(), "C10").stack.contains("carpic_leftfront_window_close"))
        assertTrue(CarLayerComposer.plan(c11(), "B01").stack.contains("carpic_leftfront_window_close"))
        assertTrue(CarLayerComposer.plan(s01(), "T03").stack.contains("carpic_leftfront_window_close"))
        // C11 那套不补窗；S01 连后窗都没有。
        assertFalse(CarLayerComposer.plan(c11(), "C11").stack.contains("carpic_leftfront_window_close"))
        assertFalse(CarLayerComposer.plan(s01(), "S01").stack.contains("carpic_leftfront_window_close"))
    }

    @Test
    fun `门开着时不补那一侧的窗`() {
        val stack = CarLayerComposer.plan(c11(VehicleSignal.DriverDoor to "1"), "C10").stack
        // 门的 open 图里自带窗，再叠一层会重影。
        assertFalse(stack.contains("carpic_leftfront_window_close"))
        assertTrue(stack.contains("carpic_leftbehind_window_close"))
    }

    @Test
    fun `带年款后缀的车型码也要落进正确的分组`() {
        // 精确匹配的话 `T03-2023` 会静悄悄落进 C11 那套：多一扇恒显示的尾门、少两层窗。
        val stack = CarLayerComposer.plan(s01(), "T03-2023").stack
        assertTrue(stack.contains("carpic_leftfront_window_close"))
        assertTrue(stack.none { it.contains("tailgate") })
    }

    // MARK: - 车型分组：充电槽位

    @Test
    fun `充电槽位按车型换 z 序`() {
        val charging = mapOf(VehicleSignal.ChargeState to "1")
        fun planFor(carType: String, legacy: Boolean) = CarLayerComposer.plan(
            if (legacy) s01(*charging.toList().toTypedArray()) else c11(*charging.toList().toTypedArray()),
            carType,
        )

        // c11：充电层在车身下面，车身及左右门全在 above。
        val c11Plan = planFor("C11", legacy = false)
        assertTrue(c11Plan.above.contains("carpic_body"))
        assertTrue(c11Plan.below.contains("carpic_rightfront_close"))

        // c10 / b11 / c16：车身上面、左后门下面。
        val c10Plan = planFor("C10", legacy = false)
        assertTrue(c10Plan.below.contains("carpic_body"))
        assertTrue(c10Plan.above.contains("carpic_leftbehind_close"))

        // t03 / s01：所有门之上。
        val t03Plan = planFor("T03", legacy = true)
        assertTrue(t03Plan.below.contains("carpic_leftfront_close"))
        assertTrue(t03Plan.above.contains("carpic_charge_open"))
    }

    @Test
    fun `b01 的门窗跟 c10 充电跟 c11`() {
        // 两套分组不是一套，这台车是唯一能把它们区分开的证据。
        val plan = CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "1"), "B01")
        assertTrue("门窗按 c10 那套补窗", plan.stack.contains("carpic_leftfront_window_close"))
        assertTrue("充电按 c11 那套画在车身下面", plan.above.contains("carpic_body"))
    }

    @Test
    fun `充电口盖只有 t03 和 s01 画，且跟着充电层一起有无`() {
        assertTrue(
            CarLayerComposer.plan(s01(VehicleSignal.ChargeState to "1"), "S01").above
                .contains("carpic_charge_open"),
        )
        // 没在充电就没有充电层，口盖也不画。
        assertFalse(
            CarLayerComposer.plan(s01(), "S01").above.contains("carpic_charge_open"),
        )
        assertFalse(
            CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "1"), "C11").above
                .contains("carpic_charge_open"),
        )
    }

    // MARK: - 充电层

    @Test
    fun `充电中的帧数按车型不同`() {
        val charging = VehicleSignal.ChargeState to "1"
        assertEquals(18, CarLayerComposer.plan(s01(charging), "S01").chargeFrames.size)
        assertEquals(14, CarLayerComposer.plan(s01(charging), "T03").chargeFrames.size)
        assertEquals(15, CarLayerComposer.plan(c11(charging), "C11").chargeFrames.size)
        // 官方是从 carpic_charge2 起连着取 n 张。
        assertEquals("carpic_charge2", CarLayerComposer.plan(c11(charging), "C11").chargeFrames.first())
        assertEquals("carpic_charge16", CarLayerComposer.plan(c11(charging), "C11").chargeFrames.last())
    }

    @Test
    fun `非充电中的几档各出一张静态图`() {
        for (raw in listOf("3", "4", "6")) {
            assertEquals(
                listOf("carpic_charge1"),
                CarLayerComposer.plan(c11(VehicleSignal.ChargeState to raw), "C11").chargeFrames,
            )
        }
        assertEquals(
            listOf("carpic_charge2"),
            CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "2"), "C11").chargeFrames,
        )
        // 读不到 chargeState 就整层不画，不替车说「在充电」。
        assertTrue(CarLayerComposer.plan(c11(), "C11").chargeFrames.isEmpty())
    }

    @Test
    fun `行驶中整层隐藏`() {
        val plan = CarLayerComposer.plan(
            c11(VehicleSignal.ChargeState to "1", VehicleSignal.GearStatus to "3"),
            "C11",
        )
        assertTrue(plan.chargeFrames.isEmpty())
        assertFalse(plan.isAnimated)
    }

    @Test
    fun `只有多帧才算动画`() {
        assertTrue(CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "1"), "C11").isAnimated)
        assertFalse(CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "2"), "C11").isAnimated)
        assertFalse(CarLayerComposer.plan(c11(), "C11").isAnimated)
    }

    // MARK: - 签名

    @Test
    fun `车况变了签名就得变`() {
        val closed = CarLayerComposer.plan(c11(), "C11").signature
        val open = CarLayerComposer.plan(c11(VehicleSignal.DriverDoor to "1"), "C11").signature
        assertNotEquals(closed, open)
        // 同样的车况要给同一个签名，否则每次刷新都白重叠一遍。
        assertEquals(closed, CarLayerComposer.plan(c11(), "C11").signature)
    }

    @Test
    fun `签名要分得开三段之间的挪动`() {
        // 充电槽位不同、图层名集合却一样的两台车，签名不能撞。
        val c11Sig = CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "1"), "C11").signature
        val c10Sig = CarLayerComposer.plan(c11(VehicleSignal.ChargeState to "1"), "C10").signature
        assertNotEquals(c11Sig, c10Sig)
    }

    @Test
    fun `读不到车况时也排得出一套完整层`() {
        // 车休眠、首启还没拉到车况都会走这条路。此时按「全关、不充电」画，
        // 而不是什么都不画——那样首页会突然掉回剪影。
        val plan = CarLayerComposer.plan(null, "C11")
        assertTrue(plan.stack.contains("carpic_body"))
        assertTrue(plan.stack.contains("carpic_tailgate_close"))
        assertTrue(plan.chargeFrames.isEmpty())
    }
}
