package org.yipao.app.ui.components

/** 与 iOS 一致：修复 H5 3.24.2 丢弃 offset/radius 的调用，仅适配已知签名。 */
internal object CarModelRendererSource {
    fun adapt(source: String): String {
        val start = source.indexOf("function _init(){")
        if (start < 0) return source
        val end = source.indexOf("function parseServerJson", start)
        if (end < 0) return source
        val initializer = source.substring(start, end)
        val call = "generateCar(t,n,r,i,o,a,s,void 0,void 0,d,v,f,_,m,g)"
        if (!initializer.contains("function e(t,n,r,i,o,a,s,l,c,u,h)") ||
            initializer.split(call).size != 2
        ) return source
        return source.replaceRange(start, end, initializer.replace(
            call, "generateCar(t,n,r,i,o,a,s,l,c,d,v,f,_,m,g)",
        ))
    }
}
