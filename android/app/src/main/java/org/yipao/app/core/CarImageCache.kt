package org.yipao.app.core

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.util.AtomicFile
import java.io.File
import java.io.IOException

/// 叠好的车图缓存。
///
/// 图层包解压在缓存目录里，冷启动时重新叠一次要读七八张 1125×525 的 PNG，
/// 在首页第一帧之前做不完——那一下就会闪一次剪影。所以把叠好的成品也存一张，
/// 启动时**同步**读它先顶上，等真实车况回来再叠新的覆盖。
object CarImageCache {

    /// 给缩放和桌面二次采样留一圈真正透明的像素，避免半透明阴影再次贴边成矩形。
    private const val SHARED_IMAGE_PADDING_PX = 4

    private val directory: File
        get() = File(AppEnv.context.cacheDir, "CarModel").apply { mkdirs() }

    /// vin 里的斜杠等一律替换成下划线，避免拼出子路径。
    private fun fileFor(vin: String): File {
        val safe = vin.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        return File(directory, "car-$safe.png")
    }

    /// 同步读上次那张，给启动第一帧用。
    fun cached(vin: String): Bitmap? {
        val file = fileFor(vin)
        if (!file.exists()) return null
        return runCatching { BitmapFactory.decodeFile(file.path, decodeOptions()) }.getOrNull()
    }

    fun store(image: Bitmap, vin: String) {
        runCatching {
            fileFor(vin).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    // MARK: - 小组件用的那一份

    /// 小组件读的车图放在 `filesDir`，**不是**上面那个缓存目录。
    ///
    /// 上面用的是 `cacheDir`，系统缺空间时说清就清。小组件不像 App，被清掉之后
    /// 没有「下次打开时重下」这回事——桌面上那张卡片会一直缺图，直到用户下次开 App。
    /// 所以这一份放不会被回收的地方。
    ///
    /// 只存当前这台车的一张：卡片本来就只显示当前车（快照也是这么定的）。
    private val sharedFile: File
        get() = File(AppEnv.context.filesDir, "car-widget.png")

    /// 给小组件写一份：裁掉四周的透明边，再缩到卡片用得上的尺寸。
    ///
    /// 官方图层是 1125×525 的宽幅画布，车只占中间一条。原样丢进小卡里，车会缩成
    /// 中间细细一道。缩到 360 宽还有另一层原因：小组件的画面是 `RemoteViews` 走
    /// **Binder 事务**送到桌面进程的，整个事务大约 1MB 封顶，而位图是按解压后的
    /// 像素算的——480 宽那张就要 430KB，两张卡片再加上文字图标很容易撞上限，
    /// 撞了是整张卡片画不出来，不是图糊一点。
    fun storeShared(image: Bitmap): Boolean = store(image, requireTransparentBorder = false)

    /// 3D 渲染器截来的那张。
    ///
    /// 和图层叠出来的不一样：它有可能整张都不透明——WebGL 的背景没抠干净、
    /// 或者截图落进了不透明的画布，都会这样。那种图写进卡片就是一整块底色，
    /// 比剪影更难看。所以要求四周留有透明边，验不过宁可不写。
    fun storeSharedRendered(image: Bitmap): Boolean =
        store(image, requireTransparentBorder = true)

    private fun store(image: Bitmap, requireTransparentBorder: Boolean): Boolean {
        val trimmed = trimmedAndScaled(image, maxWidth = 360, requireTransparentBorder)
            ?: return false
        val atomic = AtomicFile(sharedFile)
        var output: java.io.FileOutputStream? = null
        return try {
            val target = atomic.startWrite()
            output = target
            if (!trimmed.compress(Bitmap.CompressFormat.PNG, 100, target)) {
                throw IOException("PNG encoder returned false")
            }
            atomic.finishWrite(target)
            output = null
            true
        } catch (e: Throwable) {
            output?.let { atomic.failWrite(it) }
            DiagLog.note("[carmodel] 小组件车图写入失败：${e.message.orEmpty()}")
            false
        } finally {
            trimmed.recycle()
        }
    }

    fun shared(): Bitmap? {
        val atomic = AtomicFile(sharedFile)
        if (!sharedFile.exists() && !File(sharedFile.path + ".bak").exists()) return null
        return runCatching {
            atomic.openRead().use { BitmapFactory.decodeStream(it, null, decodeOptions()) }
        }.onFailure {
            DiagLog.note("[carmodel] 小组件车图读取失败：${it.message.orEmpty()}")
        }.getOrNull()
    }

    /// 退出登录、换车、关掉「显示车模型」都要清——否则卡片上会一直挂着上一台车。
    fun clearShared() {
        runCatching { AtomicFile(sharedFile).delete() }
    }

    /// 不让 BitmapFactory 按屏幕密度缩：这些图是按像素算好的，缩一道只会糊。
    private fun decodeOptions() = BitmapFactory.Options().apply { inScaled = false }

    /// 按 alpha 求出内容的外接矩形，裁掉透明边后等比缩放。
    /// 全透明（叠图失败）时返回 null，宁可让卡片退回剪影，也别写一张空图上去。
    ///
    /// `requireTransparentBorder` 要求内容四周都至少留一像素透明边，留不出就返回 null。
    /// 它是「这张图的背景真的抠掉了吗」的判据：整张不透明时外接矩形正好等于画布本身。
    private fun trimmedAndScaled(
        image: Bitmap,
        maxWidth: Int,
        requireTransparentBorder: Boolean = false,
    ): Bitmap? {
        val width = image.width
        val height = image.height
        if (width <= 0 || height <= 0) return null

        // 低于这个值的像素当成透明：图层边缘做过羽化，纯 0 的判据会把羽化带也留下来。
        val threshold = 8
        val row = IntArray(width)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        // 逐行取而不是一次拉出整张：1125×525 的 IntArray 是 2.4MB，
        // 而车图这条路径在小组件刷新时也会走，那边内存预算比 App 紧得多。
        for (y in 0 until height) {
            image.getPixels(row, 0, width, 0, y, width, 1)
            for (x in 0 until width) {
                if ((row[x] ushr 24) <= threshold) continue
                if (x < minX) minX = x
                if (x > maxX) maxX = x
                if (y < minY) minY = y
                if (y > maxY) maxY = y
            }
        }
        if (maxX < minX || maxY < minY) return null
        if (requireTransparentBorder &&
            (minX == 0 || minY == 0 || maxX == width - 1 || maxY == height - 1)
        ) {
            return null
        }

        val cropWidth = maxX - minX + 1
        val cropHeight = maxY - minY + 1
        val contentMaxWidth = (maxWidth - SHARED_IMAGE_PADDING_PX * 2).coerceAtLeast(1)
        val scale = minOf(1f, contentMaxWidth.toFloat() / cropWidth)
        val targetWidth = (cropWidth * scale).toInt().coerceAtLeast(1)
        val targetHeight = (cropHeight * scale).toInt().coerceAtLeast(1)

        val out = Bitmap.createBitmap(
            targetWidth + SHARED_IMAGE_PADDING_PX * 2,
            targetHeight + SHARED_IMAGE_PADDING_PX * 2,
            Bitmap.Config.ARGB_8888,
        )
        Canvas(out).drawBitmap(
            image,
            Rect(minX, minY, maxX + 1, maxY + 1),
            Rect(
                SHARED_IMAGE_PADDING_PX,
                SHARED_IMAGE_PADDING_PX,
                SHARED_IMAGE_PADDING_PX + targetWidth,
                SHARED_IMAGE_PADDING_PX + targetHeight,
            ),
            Paint(Paint.FILTER_BITMAP_FLAG),
        )
        return out
    }
}
