package org.yipao.app.core

import android.content.pm.ApplicationInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.CertificatePinner
import okhttp3.Headers.Companion.toHeaders
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/// 请求体形式。四选一，与 iOS 版 `request(...)` 的 jsonBody/formBody/emptyBody 对应。
enum class BodyKind { None, Json, Form, Empty }

/// 裸 HTTP 层。签名、鉴权、重试都不在这里，那些是 `LeapClient` 的事。
object HttpTransport {

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .callTimeout(40, TimeUnit.SECONDS)
            // 不留 cookie：老链路靠 header 里的 token，服务端下发的 cookie 一旦被带上，
            // 反而会在续期后拿着旧身份去撞新 token。iOS 那边用 ephemeral session 是同一个考虑。
            .cookieJar(okhttp3.CookieJar.NO_COOKIES)
            .retryOnConnectionFailure(true)
            // 正式包固定证书公钥；debug 包放行，方便抓包调试。
            .apply { if (!isDebuggable) certificatePinner(leapPinner) }
            .build()
    }

    /// debug 构建豁免证书固定，看 FLAG_DEBUGGABLE。
    private val isDebuggable: Boolean
        get() = (AppEnv.context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /// 证书固定：每个域名钉「中间 CA + 根 CA」两针，任一命中即放行。
    /// 只钉上级 CA、不钉叶证书——叶证书每年续期，钉叶会年年断网；钉中间即可扛叶轮换，
    /// 根作为备用针再兜一层。仅当零跑整体更换 CA 时才需发版更新这里。
    /// pin 值由 openssl 从实时证书链提取（SPKI SHA-256）。通配 *.leapmotor.com 顺带覆盖
    /// getCarRoute 动态返回的 appgateway.leapmotor.com，避免新域名漏钉。
    private val leapPinner: CertificatePinner by lazy {
        CertificatePinner.Builder()
            .add(
                "*.leapmotor.com",
                "sha256/gxeKFFaZ2HFJIsTdTjEl6nVo3ckTCX+qzRMqb9Xoa1w=", // 中间 Encryption Everywhere DV TLS CA - G2
                "sha256/i7WTqTvh0OioIruIfFR4kMPnBqrS2rdiVPl/s2uC/CY=", // 根 DigiCert Global Root G2
            )
            .add(
                "*.leapmotor.cn",
                "sha256/E3tYcwo9CiqATmKtpMLW5V+pzIq+ZoDmpXSiJlXGmTo=", // 中间 RapidSSL TLS RSA CA G1
                "sha256/i7WTqTvh0OioIruIfFR4kMPnBqrS2rdiVPl/s2uC/CY=", // 根 DigiCert Global Root G2
            )
            .build()
    }

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
    private val formMediaType = "application/x-www-form-urlencoded; charset=utf-8".toMediaType()

    /// 拼 query string。值按 URL 组件编码。
    fun buildURL(base: String, query: Map<String, String>?): String {
        if (query.isNullOrEmpty()) return base
        val parts = query.entries.joinToString("&") {
            "${urlEncode(it.key)}=${urlEncode(it.value)}"
        }
        val separator = if (base.contains("?")) "&" else "?"
        return base + separator + parts
    }

    /// `URLEncoder` 把空格编成 `+`，那是表单规则不是 URL 组件规则；query 里得是 `%20`。
    private fun urlEncode(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    private fun formEncode(body: Map<String, String>): String =
        body.entries.joinToString("&") { "${URLEncoder.encode(it.key, "UTF-8")}=${URLEncoder.encode(it.value, "UTF-8")}" }

    /// 发一个 JSON 请求。非 2xx 抛 `LeapError.http`。
    suspend fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        query: Map<String, String>? = null,
        bodyKind: BodyKind = BodyKind.None,
        body: Map<String, String>? = null,
    ): JsonValue = withContext(Dispatchers.IO) {
        val requestUrl = buildURL(url, query)
        val httpUrl = requestUrl.toHttpUrlOrNull()
            ?: throw LeapError.http(0, "URL 不合法：${requestUrl.substringBefore('?')}")

        val requestBody: RequestBody? = when {
            bodyKind == BodyKind.Json && body != null -> {
                val obj = org.json.JSONObject()
                body.forEach { (key, value) -> obj.put(key, value) }
                obj.toString().toRequestBody(jsonMediaType)
            }

            bodyKind == BodyKind.Form && body != null -> formEncode(body).toRequestBody(formMediaType)
            // Empty：POST 但没有 body。OkHttp 的 POST 必须给一个 body 对象，
            // 给零长度的即可——发出去就是 Content-Length: 0，与 iOS 给这类接口发空 body 一致。
            bodyKind == BodyKind.Empty -> ByteArray(0).toRequestBody(null)
            method == "POST" -> ByteArray(0).toRequestBody(null)
            else -> null
        }

        val request = Request.Builder()
            .url(httpUrl)
            .headers(headers.toHeaders())
            .method(method, requestBody)
            .build()

        // 只打方法和路径：query 里带着加密手机号和签名，不能进日志。
        val path = requestUrl.substringBefore('?')
        val started = System.currentTimeMillis()
        DiagLog.note("[http] → $method $path")

        val text: String
        val status: Int
        try {
            client.newCall(request).execute().use { response ->
                status = response.code
                text = response.body?.string().orEmpty()
            }
        } catch (e: LeapError) {
            throw e
        } catch (e: Exception) {
            DiagLog.note("[http] ✗ $method $path ${System.currentTimeMillis() - started}ms ${LeapError.messageOf(e)}")
            throw e
        }
        DiagLog.note("[http] ← $status $method $path ${System.currentTimeMillis() - started}ms")

        val value: JsonValue = if (text.isEmpty()) {
            JsonValue.Null
        } else {
            // 解不动的（网关的 HTML 错误页）也别丢，包一层塞给上层，排查时能看到原文。
            JsonValue.parse(text) ?: JsonValue.of(mapOf("raw" to JsonValue.of(text)))
        }

        if (status !in 200..299) {
            val message = value.responseMessage.ifEmpty { text.take(200) }
            throw LeapError.http(status, message)
        }
        value
    }

    /// 下载二进制（车模型 ZIP）。失败返回 null——车模型拉不到只是少张图，不该把调用方打断。
    suspend fun download(
        url: String,
        headers: Map<String, String> = emptyMap(),
    ): ByteArray? = withContext(Dispatchers.IO) {
        val httpUrl = url.toHttpUrlOrNull() ?: return@withContext null
        try {
            val request = Request.Builder().url(httpUrl).headers(headers.toHeaders()).get().build()
            // 车模型 ZIP 有十几 MB，走整体 2 分钟的超时，别用默认那个 40 秒的 callTimeout。
            client.newBuilder()
                .callTimeout(120, TimeUnit.SECONDS)
                .readTimeout(120, TimeUnit.SECONDS)
                .build()
                .newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@withContext null
                    response.body?.bytes()
                }
        } catch (e: Exception) {
            DiagLog.note("[http] ✗ 下载失败 ${LeapError.messageOf(e)}")
            null
        }
    }
}
