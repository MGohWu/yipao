package org.yipao.app.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class CarModelRendererSourceTest {
    private val call = "generateCar(t,n,r,i,o,a,s,void 0,void 0,d,v,f,_,m,g)"
    private val signature = "function e(t,n,r,i,o,a,s,l,c,u,h)"
    private fun source(body: String = "$signature{$call}") =
        "before;$call;function _init(){$body}function parseServerJson(){};$call"

    @Test fun restoresCameraArgumentsOnlyInsideKnownInitializer() {
        val original = source()
        val expected = source("$signature{generateCar(t,n,r,i,o,a,s,l,c,d,v,f,_,m,g)}")
        assertEquals(expected, CarModelRendererSource.adapt(original))
        assertEquals(expected, CarModelRendererSource.adapt(expected))
    }

    @Test fun leavesUnknownOrAmbiguousRendererUntouched() {
        listOf(
            source().replace(signature, "function e(t,n)"),
            source("$signature{$call;$call}"),
            source().replace("function parseServerJson", "function other"),
            source().replace("function _init(){", "function otherInit(){"),
            "",
        ).forEach { assertEquals(it, CarModelRendererSource.adapt(it)) }
    }
}
