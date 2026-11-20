package org.yipao.app.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.ZipInputStream

/// 车模资源的本地目录：下载 ZIP、解压、按车缓存。
///
/// 目录布局照着渲染器的相对路径来——渲染器包里的 `index.js` 用
/// `./C11_2026/C11_2026_full_car.fbx` 这样的相对路径取模型，所以模型包必须
/// 解到渲染器同一级：
///
///     <cacheDir>/CarModel3D/<vin>/
///       ├─ index.html / index.js / FBX.worker.js / models/ / textures/   ← 渲染器包
///       └─ C11_2026/…                                                    ← 模型包
///
/// 一辆车约 14MB，放 `cacheDir`：系统缺空间时可以回收，回收了下次自动重下。
object CarModelAssets {

    /// 解压完成的标记。两个包都解开才写，避免半成品被当成可用。
    private const val READY_MARKER = ".ready"

    fun directory(vin: String): File =
        File(File(AppEnv.context.cacheDir, "CarModel3D"), sanitize(vin))

    private fun sanitize(raw: String): String =
        raw.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")

    /// 3D 资源是否已就绪。顺带校验入口文件还在——缓存目录可能被系统清掉一部分。
    fun isReady(vin: String): Boolean {
        val dir = directory(vin)
        return File(dir, READY_MARKER).exists() && File(dir, "index.html").exists()
    }

    /// 2D 图层包是否已就绪。
    fun areLayersReady(vin: String): Boolean {
        val dir = directory(vin)
        return File(dir, READY_MARKER).exists() && CarLayerComposer.layerDirectory(dir) != null
    }

    /// 准备 2D 图层包。没有 3D 的车型（S01、C10…）用 `srcKey` 换到的是这一套图层，
    /// 官方爱车页那张会跟着车况变的图就是它叠出来的。
    suspend fun prepareLayers(
        vin: String,
        model: CarModel,
        forceRefresh: Boolean = false,
        download: suspend (String) -> ByteArray,
    ): File = withContext(Dispatchers.IO) {
        val dir = directory(vin)
        if (!forceRefresh && areLayersReady(vin)) return@withContext dir

        prepareDirectory(dir, keepCurrent = forceRefresh) { target ->
            extract(download(model.srcKey), target)
            if (CarLayerComposer.layerDirectory(target) == null) {
                throw LeapError.server("图层包里没有 android/<density> 目录")
            }
        }
    }

    /// 准备 3D 资源：已就绪直接返回目录；否则下载两个包解压。
    ///
    /// `download` 由调用方注入（`LeapClient.fetchCarModelPackage`），
    /// 这样这里不依赖网络层，测试时也能塞本地包。
    suspend fun prepare(
        vin: String,
        model: CarModel,
        forceRefresh: Boolean = false,
        download: suspend (String) -> ByteArray,
    ): File = withContext(Dispatchers.IO) {
        val dir = directory(vin)
        if (!forceRefresh && isReady(vin)) return@withContext dir

        prepareDirectory(dir, keepCurrent = forceRefresh) { target ->
            // 渲染器包在外层，模型包解进去后正好是它的同级子目录。
            extract(download(model.h5Key), target)
            extract(download(model.srcKey), target)
            if (!File(target, "index.html").exists()) {
                throw LeapError.server("渲染器包里没有 index.html")
            }
        }
    }

    /// 手动刷新时先在同级临时目录里下载、解压和校验，最后才替换正式目录。
    /// 下载失败时旧资源仍可继续渲染，不能因为用户点了一次刷新就让车模消失。
    private suspend fun prepareDirectory(
        dir: File,
        keepCurrent: Boolean,
        populate: suspend (File) -> Unit,
    ): File {
        if (!keepCurrent) {
            dir.deleteRecursively()
            dir.mkdirs()
            try {
                populate(dir)
                File(dir, READY_MARKER).writeBytes(ByteArray(0))
                return dir
            } catch (e: Throwable) {
                dir.deleteRecursively()
                throw e
            }
        }

        val parent = dir.parentFile ?: throw IOException("车模型目录没有父目录")
        parent.mkdirs()
        val incoming = File(parent, dir.name + ".incoming")
        val backup = File(parent, dir.name + ".backup")
        incoming.deleteRecursively()
        backup.deleteRecursively()
        incoming.mkdirs()
        try {
            populate(incoming)
            File(incoming, READY_MARKER).writeBytes(ByteArray(0))
            replaceDirectory(dir, incoming, backup)
            return dir
        } catch (e: Throwable) {
            incoming.deleteRecursively()
            throw e
        }
    }

    private fun replaceDirectory(current: File, incoming: File, backup: File) {
        val hadCurrent = current.exists()
        if (hadCurrent && !current.renameTo(backup)) {
            throw IOException("无法备份当前车模型")
        }
        if (!incoming.renameTo(current)) {
            if (hadCurrent) backup.renameTo(current)
            throw IOException("无法启用新车模型")
        }
        backup.deleteRecursively()
    }

    /// 从解压出来的目录名反推车型别名，`Lafa5_2026/` → `Lafa5`。
    ///
    /// 存在的理由：渲染器按 `<别名>_<年款>/` 取资源，而别名不一定等于 `carType`。
    /// B05 的资源目录叫 `Lafa5_2026`（Lafa5 是它的内部代号），按 carType 拼必然 404。
    /// 接口的 `modelParam` 里没有这个别名——只有 carType/carTypeCode/colorCode/year 四项，
    /// 所以唯一可靠的来源就是包自己解出来的目录名。这样新车型不用维护映射表。
    ///
    /// 渲染器缺省的 `"lafa5"` 顶不上：**安卓的 ext4 也是大小写敏感的**，`lafa5_2026`
    /// 命不中 `Lafa5_2026`。必须按目录名原样传。
    ///
    /// B05 会同时解出 `Lafa5_2026` 和 `Lafa5Ultra_2026` 两套，靠 `carTypeCode` 里
    /// 有没有 `ultra` 区分——和渲染器 `confirmVehicleLoad` 自己那段特判同一个判据。
    fun assetAlias(root: File, carTypeCode: String): String? {
        val names = (root.listFiles() ?: return null)
            .filter { it.isDirectory }
            .map { it.name }
            // `<名字>_<四位年款>`。渲染器自带的 models/、textures/ 不长这样，自然被滤掉。
            .filter { name ->
                val separator = name.lastIndexOf('_')
                if (separator <= 0) return@filter false
                val year = name.substring(separator + 1)
                year.length == 4 && year.all { it.isDigit() }
            }
            .map { it.substring(0, it.lastIndexOf('_')) }
        if (names.isEmpty()) return null

        val wantsUltra = carTypeCode.lowercase().contains("ultra")
        val matched = names.filter { it.lowercase().contains("ultra") == wantsUltra }
        // 挑不出对应版本就退回任意一个：拼错版本也比拼一个必然 404 的 carType 强。
        return matched.firstOrNull() ?: names.first()
    }

    /// 换车或换车型版本时清掉旧资源。
    fun clear(vin: String) {
        directory(vin).deleteRecursively()
    }

    // MARK: - 解压

    /// 把 ZIP 解到 `destination`。
    ///
    /// 条目路径必须逐个校验落点还在目标目录内（zip slip）：包是从服务端下来的，
    /// 一个 `../../databases/leap.db` 的条目就能把 App 自己的文件覆盖掉。
    /// `canonicalPath` 而不是简单拼字符串——`a/../../b` 这种要先归一化才看得出越界。
    private fun extract(payload: ByteArray, destination: File) {
        val root = destination.canonicalFile
        ZipInputStream(payload.inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val target = File(root, entry.name).canonicalFile
                if (!target.path.startsWith(root.path + File.separator)) {
                    throw LeapError.server("资源包里有越界路径：${entry.name}")
                }
                if (entry.isDirectory) {
                    target.mkdirs()
                } else {
                    target.parentFile?.mkdirs()
                    target.outputStream().use { out -> copy(zip, out) }
                }
                zip.closeEntry()
            }
        }
    }

    private fun copy(input: InputStream, output: java.io.OutputStream) {
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            output.write(buffer, 0, read)
        }
    }
}
