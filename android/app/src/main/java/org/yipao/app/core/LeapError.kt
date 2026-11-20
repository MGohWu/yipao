package org.yipao.app.core

import kotlinx.coroutines.CancellationException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/// 业务错误分类。kind 用于分流处理（会话过期要踢回登录页，网络错误不能）。
enum class LeapErrorKind {
    Crypto,
    NotLoggedIn,

    /// 服务端明确拒绝了当前登录态，且续期也救不回来——只能重新短信登录。
    SessionExpired,

    /// 老链路持续判定「信息校验失败」（result=39），刷新 token 也救不回来。
    ///
    /// 和 `SessionExpired` 分开：那个会清会话回登录页（连蓝牙钥匙证书一起清掉），
    /// 而这个状态未必是登录态没了——本机的设备号和服务端记的那个对不上时，
    /// refreshToken 完全有效、车况照常刷新，只有老链路（远控/里程/位置）全废。
    /// 这种情况只有重新短信登录才解得开，但不该由 App 替用户做决定，只提示。
    NeedsRelogin,
    MissingVehicle,
    Server,
    Http,
    Decode,

    /// 网络层失败：连不上、超时、连接被断。和 `SessionExpired` 严格分开——
    /// 断网只是这次请求没成，不能据此把用户踢回登录页。
    Network,
}

class LeapError(
    val kind: LeapErrorKind,
    override val message: String,
    val httpStatus: Int = 0,
) : Exception(message) {

    companion object {
        fun crypto(message: String) = LeapError(LeapErrorKind.Crypto, message)

        fun notLoggedIn() = LeapError(LeapErrorKind.NotLoggedIn, "还没有登录，请先完成短信验证码登录")

        fun sessionExpired() = LeapError(LeapErrorKind.SessionExpired, "登录已过期，请重新登录")

        fun needsRelogin() = LeapError(LeapErrorKind.NeedsRelogin, "控车授权已失效，请重新登录")

        fun missingVehicle() = LeapError(LeapErrorKind.MissingVehicle, "还没有选择车辆")

        fun server(message: String) = LeapError(LeapErrorKind.Server, message)

        fun http(status: Int, body: String) =
            LeapError(LeapErrorKind.Http, "HTTP $status：$body", status)

        fun decode(message: String) = LeapError(LeapErrorKind.Decode, "响应解析失败：$message")

        fun network(message: String) = LeapError(LeapErrorKind.Network, message)

        /// 把网络层异常翻成用户看得懂的话，其余异常原样放行。
        ///
        /// 不翻的话弹给用户的是 `java.net.SocketTimeoutException: timeout` 这种类名，
        /// 在「锁屏久了再解锁」这个场景里既吓人又误导：用户的网络好好的，
        /// 坏掉的是 App 手里那条已经死了的复用连接。
        ///
        /// **协程取消不翻**：切车、退到后台停轮询都会取消在途请求，翻了就成了平白弹一条
        /// 网络错误；而且 `CancellationException` 必须原样往外抛，否则结构化并发的取消链
        /// 会在这里被吞掉，协程作用域再也收不拢。
        fun wrapping(e: Throwable): Throwable = when (e) {
            is CancellationException -> e
            is LeapError -> e
            // InterruptedIOException 是 SocketTimeoutException 的父类，也是 OkHttp
            // callTimeout 超时时抛的那一个，两个都归超时。
            is SocketTimeoutException, is InterruptedIOException ->
                network("网络响应超时，请稍后重试")
            // DNS 解不出：可能真断网，也可能是被劫持。两种都先让用户看网络。
            is UnknownHostException -> network("网络连接不可用，请检查网络后重试")
            is ConnectException, is NoRouteToHostException, is SSLException ->
                network("连接服务器失败，请稍后重试")
            // 剩下的 IO 异常多是连接被对端断开一类，带上类名方便照着日志定位。
            is IOException -> network("网络请求失败（${e::class.simpleName}）")
            else -> e
        }

        /// 把任意抛出的异常转成用户可读文案。
        ///
        /// 平台异常（IOException、GeneralSecurityException）的 message 经常是英文类名或者
        /// 干脆是 null，直接甩给用户等于什么都没说，所以 message 为空时退回类名。
        fun messageOf(e: Throwable?): String {
            if (e == null) return "未知错误"
            val message = e.message.orEmpty()
            if (message.isNotEmpty()) return message
            // 连 message 都没有，退回简名——总比空字符串多一点信息。
            return e::class.simpleName ?: "未知错误"
        }
    }
}
