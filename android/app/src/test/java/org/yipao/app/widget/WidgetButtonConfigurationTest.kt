package org.yipao.app.widget

import org.yipao.app.app.WidgetControlRunner
import org.yipao.app.core.LeapCommand
import org.yipao.app.core.LeapDeepLink
import org.yipao.app.core.VehicleSnapshot
import org.yipao.app.core.WidgetAction
import org.yipao.app.core.WidgetButtonLayout
import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetButtonConfigurationTest {
    @Test
    fun oldAndInvalidSettingsKeepCompleteLayouts() {
        assertEquals(WidgetButtonLayout.defaults, WidgetButtonLayout.normalize(emptyList(), false))
        assertEquals(listOf(WidgetAction.Unlock, WidgetAction.Lock),
            WidgetButtonLayout.normalize(listOf("unlock", "invalid", "unlock", "lock"), true))
        assertEquals(listOf(WidgetAction.Unlock, WidgetAction.ToggleLock, WidgetAction.ToggleClimate, WidgetAction.Trunk),
            WidgetButtonLayout.normalize(listOf("unlock", "invalid", "unlock"), false))
    }

    @Test
    fun choosingAnExistingActionSwapsPositionsWithoutDuplicates() {
        val actions = listOf(WidgetAction.Lock, WidgetAction.Unlock, WidgetAction.Horn, WidgetAction.Trunk)
        assertEquals(listOf(WidgetAction.Unlock, WidgetAction.Lock, WidgetAction.Horn, WidgetAction.Trunk),
            WidgetButtonLayout.replacing(actions, 0, WidgetAction.Unlock))
    }

    @Test
    fun draggingMovesTheButtonAndKeepsOtherButtonsInOrder() {
        val actions = listOf(WidgetAction.Lock, WidgetAction.Unlock, WidgetAction.Horn, WidgetAction.Trunk)
        assertEquals(listOf(WidgetAction.Unlock, WidgetAction.Horn, WidgetAction.Trunk, WidgetAction.Lock),
            WidgetButtonLayout.moving(actions, 0, 3))
        assertEquals(listOf(WidgetAction.Trunk, WidgetAction.Lock, WidgetAction.Unlock, WidgetAction.Horn),
            WidgetButtonLayout.moving(actions, 3, 0))
        assertEquals(actions, WidgetButtonLayout.moving(actions, -1, 2))
        assertEquals(actions, WidgetButtonLayout.moving(actions, 2, 2))
    }

    @Test
    fun explicitLockCommandsIgnoreSnapshotAndToggleDirection() {
        listOf(true, false, null).forEach { locked ->
            val snapshot = VehicleSnapshot.placeholder.copy(isLocked = locked)
            assertCommand(LeapCommand.lock(), WidgetControlRunner.command(WidgetAction.Lock, snapshot, false))
            assertCommand(LeapCommand.unlock(), WidgetControlRunner.command(WidgetAction.Unlock, snapshot, true))
        }
        assertCommand(LeapCommand.lock(), WidgetControlRunner.command(WidgetAction.Lock, null, null))
        assertCommand(LeapCommand.unlock(), WidgetControlRunner.command(WidgetAction.Unlock, null, null))
        assertEquals("leapcontrol://action?a=lock", LeapDeepLink.action(WidgetAction.Lock))
        assertEquals("leapcontrol://action?a=unlock", LeapDeepLink.action(WidgetAction.Unlock))
    }

    @Test
    fun widgetBroadcastOnlyAcceptsKnownActions() {
        assertEquals(
            WidgetBroadcastRequest.Control(WidgetAction.ToggleClimate, null),
            parseWidgetBroadcast(WidgetActionReceiver.ACTION_CONTROL, "toggleClimate", null),
        )
        assertEquals(
            WidgetBroadcastRequest.Control(WidgetAction.ToggleLock, false),
            parseWidgetBroadcast(WidgetActionReceiver.ACTION_CONTROL, "toggleLock", false),
        )
        assertEquals(
            WidgetBroadcastRequest.Refresh,
            parseWidgetBroadcast(WidgetActionReceiver.ACTION_REFRESH, null, null),
        )
        assertEquals(null, parseWidgetBroadcast(WidgetActionReceiver.ACTION_CONTROL, "bad", null))
        assertEquals(null, parseWidgetBroadcast("unknown", "lock", true))
    }

    private fun assertCommand(expected: LeapCommand, actual: LeapCommand) {
        assertEquals(expected.cmdid, actual.cmdid)
        assertEquals(expected.stateJSON, actual.stateJSON)
        assertEquals(expected.bleCommand, actual.bleCommand)
    }
}
