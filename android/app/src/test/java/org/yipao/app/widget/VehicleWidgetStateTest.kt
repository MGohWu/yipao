package org.yipao.app.widget

import org.yipao.app.R
import org.junit.Assert.assertEquals
import org.junit.Test

class VehicleWidgetStateTest {

    @Test
    fun lockVisualsMapEveryStateExplicitly() {
        assertEquals(R.drawable.ic_widget_lock, lockIcon(true))
        assertEquals(WidgetTint.Accent, lockTint(true))

        assertEquals(R.drawable.ic_widget_lock_open, lockIcon(false))
        assertEquals(WidgetTint.Caution, lockTint(false))

        assertEquals(R.drawable.ic_widget_warning, lockIcon(null))
        assertEquals(WidgetTint.Neutral, lockTint(null))
    }
}
