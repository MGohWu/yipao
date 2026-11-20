package org.yipao.app.ui.components

import java.io.File

/// 根目录和目标文件都规范化，避免 Android 数据目录别名被误判为越界。
internal class CarModelResourceFiles(root: File) {
    private val canonicalRoot = root.canonicalFile

    fun resolve(relativePath: String): File? {
        val target = File(canonicalRoot, relativePath).canonicalFile
        return target.takeIf {
            it.path.startsWith(canonicalRoot.path + File.separator) && it.isFile
        }
    }
}
