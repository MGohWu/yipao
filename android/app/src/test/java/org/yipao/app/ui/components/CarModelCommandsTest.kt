package org.yipao.app.ui.components

import org.yipao.app.core.SignalSchema
import org.yipao.app.core.VehicleSignal
import org.yipao.app.core.VehicleState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// 推给 3D 渲染器的命令数组。
///
/// 为什么要钉在单测里：这串 JSON 的键名和分组结构抄自渲染器自己的 `controller`
/// 分发表，写错了渲染器**不报错**——它只是匹配不到那个 type，那扇门就永远不动。
/// 和 2D 层序一个性质：错了没人告诉你，只能对着官方 App 一样样比。
///
/// 另一条容易想当然的规则单独列了用例：**读不到的门不发命令**。
/// 「不知道开没开」不等于「关着」，发一条 `open:false` 会把车门硬关回去。
class CarModelCommandsTest {

    /// 按 schema 自己的候选 key 造车况，免得测试里硬写 `"1277"` 这种数字 ID——
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

    // MARK: - 门

    @Test
    fun `四扇门读得到就都发，关着也要发`() {
        val json = CarModelCommands.of(
            c11(
                VehicleSignal.DriverDoor to "0",
                VehicleSignal.PassengerDoor to "0",
                VehicleSignal.LeftRearDoor to "0",
                VehicleSignal.RightRearDoor to "0",
            )
        )
        // 关着也要发：模型可能还停在上一次的开门姿势，不发就收不回去。
        assertTrue(json.contains("""{"type":"LeftFront_Door","open":false}"""))
        assertTrue(json.contains("""{"type":"RightFront_Door","open":false}"""))
        assertTrue(json.contains("""{"type":"LeftRear_Door","open":false}"""))
        assertTrue(json.contains("""{"type":"RightRear_Door","open":false}"""))
    }

    @Test
    fun `读不到的门一条命令都不发`() {
        // 只有主驾这一路读得到，其余三扇不该出现——不知道开没开，不等于关着。
        val json = CarModelCommands.of(c11(VehicleSignal.DriverDoor to "1"))
        assertTrue(json.contains("""{"type":"LeftFront_Door","open":true}"""))
        assertFalse(json.contains("RightFront_Door"))
        assertFalse(json.contains("LeftRear_Door"))
        assertFalse(json.contains("RightRear_Door"))
    }

    @Test
    fun `尾门跟四扇门同一组，排在最后`() {
        val json = CarModelCommands.of(
            c11(
                VehicleSignal.DriverDoor to "0",
                VehicleSignal.TrunkOpen to "1",
            )
        )
        // 渲染器把尾门也当一扇门派发，不是单独一组。
        assertTrue(
            json.contains(
                """{"type":"Door","command":[""" +
                    """{"type":"LeftFront_Door","open":false},""" +
                    """{"type":"Trunk","open":true}]}"""
            )
        )
    }

    @Test
    fun `一扇门都读不到时连门这一组都不出现`() {
        val json = CarModelCommands.of(c11(VehicleSignal.ChargeState to "1"))
        assertFalse(json.contains("\"Door\""))
    }

    // MARK: - 窗

    @Test
    fun `车窗按开度换成开合，大于零才算开`() {
        val json = CarModelCommands.of(
            c11(
                VehicleSignal.LeftFrontWindow to "0",
                VehicleSignal.RightFrontWindow to "1",
                VehicleSignal.LeftRearWindow to "60",
                VehicleSignal.RightRearWindow to "100",
            )
        )
        assertTrue(json.contains("""{"type":"LeftFront_Window","open":false}"""))
        // 1% 也是开着：渲染器只认开合，缝着的窗照样得画成开。
        assertTrue(json.contains("""{"type":"RightFront_Window","open":true}"""))
        assertTrue(json.contains("""{"type":"LeftRear_Window","open":true}"""))
        assertTrue(json.contains("""{"type":"RightRear_Window","open":true}"""))
    }

    @Test
    fun `S01 那套反向刻度不能直接当百分比用`() {
        // S01 报的是 0…10 且方向相反：10 才是关闭、0 是全开。
        // 直接拿原始值判 `> 0` 的话，关好的窗会被当成开着。
        val closed = CarModelCommands.of(s01(VehicleSignal.LeftFrontWindow to "10"))
        assertTrue(closed.contains("""{"type":"LeftFront_Window","open":false}"""))

        val wideOpen = CarModelCommands.of(s01(VehicleSignal.LeftFrontWindow to "0"))
        assertTrue(wideOpen.contains("""{"type":"LeftFront_Window","open":true}"""))
    }

    @Test
    fun `读不到开度的窗不发命令`() {
        val json = CarModelCommands.of(c11(VehicleSignal.LeftFrontWindow to "0"))
        assertTrue(json.contains("LeftFront_Window"))
        assertFalse(json.contains("RightFront_Window"))
        assertFalse(json.contains("LeftRear_Window"))
        assertFalse(json.contains("RightRear_Window"))
    }

    // MARK: - 充电

    @Test
    fun `充电组永远发，哪怕整份车况都读不到`() {
        // 门窗可以「不知道」，充电不行：充电枪的模型只有收到 false 才会拔掉。
        val blank = CarModelCommands.of(c11())
        assertEquals("""[{"type":"Charge","command":[{"type":"Charge","open":false}]}]""", blank)
    }

    @Test
    fun `只有充电中才算插着枪`() {
        // chargeState 1 是充电中；2（插枪待机）、4（预约等待）在 3D 里都不插枪，
        // 和 2D 图层那边「静态充电图」的口径不同——渲染器只有开合两态。
        assertTrue(
            CarModelCommands.of(c11(VehicleSignal.ChargeState to "1"))
                .contains("""{"type":"Charge","open":true}""")
        )
        assertTrue(
            CarModelCommands.of(c11(VehicleSignal.ChargeState to "2"))
                .contains("""{"type":"Charge","open":false}""")
        )
    }

    // MARK: - 整体

    @Test
    fun `三组的顺序固定：门、窗、充电`() {
        val json = CarModelCommands.of(
            c11(
                VehicleSignal.DriverDoor to "0",
                VehicleSignal.LeftFrontWindow to "0",
                VehicleSignal.ChargeState to "1",
            )
        )
        val door = json.indexOf("\"Door\"")
        val window = json.indexOf("\"Window\"")
        val charge = json.indexOf("\"Charge\"")
        assertTrue(door in 0 until window)
        assertTrue(window < charge)
        // 整串必须是个合法的数组字面量，渲染器那边是 `window.controller(<这里>)`。
        assertTrue(json.startsWith("[") && json.endsWith("]"))
    }

    @Test
    fun `车况没变时两次算出来的命令要完全一样`() {
        // `push` 靠字符串相等去重，顺序只要抖一下就会每轮轮询都重放一遍动画。
        val pairs = arrayOf(
            VehicleSignal.DriverDoor to "1",
            VehicleSignal.RightRearDoor to "0",
            VehicleSignal.LeftFrontWindow to "30",
            VehicleSignal.ChargeState to "1",
        )
        assertEquals(CarModelCommands.of(c11(*pairs)), CarModelCommands.of(c11(*pairs)))
    }
}
