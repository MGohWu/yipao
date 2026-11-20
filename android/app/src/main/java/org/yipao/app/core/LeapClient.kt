package org.yipao.app.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.URLEncoder
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

/// 零跑中国 App 链路客户端。
///
/// 服务端同时存在两套鉴权：
/// - 老链路（appuser.leapmotor.cn / carownerservice / 远控）：MD5 短签名 + `XFX-CDN-CROSS-NODE` token。
/// - 新网关（app-gw-global）：HMAC-SHA256(signKey) 签名 + JWT accessToken。
/// 远控、里程、位置走老链路，车辆列表/路由/车况走新网关，两条链路的 token 各自续期。
///
/// 与 iOS 的两处结构差异（其余逐行对齐）：
/// 1. iOS 用 `actor` 做隔离，这里用一把普通的 `lock` 守住会话的读-改-写。临界区里
///    没有挂起点，语义和 actor 在 await 处让出是一致的。
/// 2. iOS 的续期互斥是 `CrossProcessLock`（App 和卡片扩展是两个进程）。安卓的小组件、
///    快捷设置磁贴默认跑在应用自己的进程里，没有跨进程窗口，一把 `Mutex` 就够。
///    `authRevision` 那套仍然保留——进程被系统回收重建后，内存里的凭证可能比存储里的旧。
class LeapClient(private val store: SessionStore = SessionStore()) {

    @Volatile
    private var current: LeapSession

    /// 启动那一帧的会话快照。
    ///
    /// 界面第一帧等不了一次异步读——等的结果就是首帧按「没登录」渲染，登录页闪一下
    /// 再被首页盖掉。存储本身是同步读的，所以这里在构造时留一份副本，专供首帧判断登录态。
    /// 之后的会话变更（登录、续期、退出）一律走 `current`，这份不再更新。
    val initialSession: LeapSession

    private val lock = Any()

    /// 续期互斥。两条链路共用一把：老链路续期尾部还会重换新网关凭证，两把锁反而要考虑重入。
    /// 锁内第一件事永远是 `syncAuthFromStore()`——等锁的这段时间里，别人多半已经换好写回了。
    private val refreshMutex = Mutex()

    /// 启动那帧存储读失败了（不是「没有」，是「读不到」）。
    /// 那一帧会把有登录态的用户判成未登录，靠 `restoreSessionFromStore()` 自愈。
    @Volatile
    private var startupLoadFailed: Boolean

    /// 充电配置最多缓存 15 秒；进入编辑页和保存后强制读取。
    private var commonConfigCacheVin: String? = null
    private var commonConfigFetchedAt = 0L
    private var commonConfigAccount: String? = null
    private var commonConfigRequest = 0L
    private var cachedChargePlan: ChargePlan? = null
    private var cachedChargePlanLimit: Int? = null

    init {
        val restored: LeapSession
        when (val outcome = store.loadOutcome()) {
            is SessionStore.LoadOutcome.Found -> {
                restored = outcome.session
                startupLoadFailed = false
            }

            is SessionStore.LoadOutcome.Missing -> {
                restored = LeapSession.fresh()
                startupLoadFailed = false
            }

            is SessionStore.LoadOutcome.Failure -> {
                // 密钥库这一次不可用（直接启动加密阶段被拉起、安全硬件忙）。这一帧按未登录
                // 渲染无可避免，但绝不能把「读不到」定论成「没登录」。
                restored = LeapSession.fresh()
                startupLoadFailed = true
                AuthAuditLog.note("启动时读会话失败（${outcome.reason}），本帧按未登录处理，待前台自愈")
            }
        }
        current = restored
        initialSession = restored
    }

    fun currentSession(): LeapSession = current

    /// 启动那帧没读到会话时的自愈：重读一次，读到登录态就整份采纳。
    ///
    /// 只在 `startupLoadFailed` 时才尝试——正常冷启动读到「确实没有」的，是真退登了。
    /// 这个区分还挡住一个更隐蔽的坑：用户正在登录页输验证码时切走再切回（复制验证码就会），
    /// 回前台若无条件重读，可能捞出一份被挤下线的作废旧会话，把登录页顶掉再被踢回来。
    ///
    /// 采纳是整份的（包括选中车、车辆列表）：本进程手里本来就是空的，没有覆盖问题。
    fun restoreSessionFromStore(): Boolean = synchronized(lock) {
        if (!startupLoadFailed || current.isLoggedIn || current.hasAnyCredential) return false
        val outcome = store.loadOutcome() as? SessionStore.LoadOutcome.Found ?: return false
        // 只留一次机会给「读失败」：这次读成功了，无论里面有没有登录态，结论都定了。
        startupLoadFailed = false
        if (!outcome.session.isLoggedIn) return false
        current = outcome.session
        AuthAuditLog.note("前台重读会话成功，恢复登录态（启动那帧读失败被误判成未登录）")
        return true
    }

    // MARK: - 落盘

    private fun persist() = synchronized(lock) {
        // 落盘前先看一眼别处有没有换发过凭证。整份写回是会覆盖的：本实例内存里那份 token
        // 可能是几小时前的，直接盖上去等于把刚换来的新 token 抹掉，下次续期就拿着作废的
        // refreshToken 去问服务端，被拒后判成登录失效。
        syncAuthLocked()
        // 设备号是空的，说明本入口启动那帧存储读失败、刚才 `syncAuthLocked()` 也没能读回来。
        // 整份写回会把存储里那个真设备号抹成空，老链路从此全废，且杀进程、重启手机都恢复
        // 不了——见 `adoptDeviceIdLocked`。
        if (current.deviceId.isEmpty()) {
            AuthAuditLog.note("跳过整份落盘：本入口还没拿到 deviceId")
            return
        }
        if (!shouldPersistWholeSession()) return
        store.save(current)
    }

    /// 整份写回之前的最后一道闸：本入口手里这份是不是「空快照」。
    ///
    /// 设备号只是被这个问题咬得最狠的那个字段，选中车同样会被盖：启动那帧存储读失败的
    /// 入口（磁贴、小组件、前台服务）内存里选中车是空的，它一次 `persist()` 就把
    /// 存储里那辆抹掉——界面读内存、会员判定读存储，两边从此认的不是同一辆车。
    ///
    /// 判据分两层，对应存储的三态：
    /// - `Failure`：这一次读不到，那就什么都别写。手里这份到底全不全，现在根本无从判断。
    /// - `Found`：存储里有选中车而本入口没有，说明本入口这份是坏快照。反过来不成立——
    ///   选中车合法地变空只发生在退登/重置，而那两条走的是 `persistAuth()`，不经过这里。
    private fun shouldPersistWholeSession(): Boolean = when (val outcome = store.loadOutcome()) {
        is SessionStore.LoadOutcome.Failure -> {
            AuthAuditLog.note("跳过整份落盘：这一次读不到存储（${outcome.reason}），无从判断手里这份全不全")
            false
        }

        SessionStore.LoadOutcome.Missing -> true

        is SessionStore.LoadOutcome.Found -> {
            val latest = outcome.session
            if (current.selectedVin.isEmpty() && latest.selectedVin.isNotEmpty()) {
                AuthAuditLog.note(
                    "跳过整份落盘：本入口手里没有选中车，存储那份有（${DiagLog.maskVin(latest.selectedVin)}）"
                )
                false
            } else {
                true
            }
        }
    }

    /// 凭证变更后**整份**落盘：打上新的版本号，别处据此认账。
    ///
    /// 整份写回意味着本实例手里的选中车、车辆列表也会一起盖上去，所以只有**本实例就是权威**
    /// 的那几步能用它：登录（要把上一个账号的车清空）、退登、重置会话。续期不行——见 `persistTokens()`。
    private fun persistAuth() = synchronized(lock) {
        current = current.copy(authRevision = System.currentTimeMillis())
        store.save(current)
    }

    /// 续期后落盘，**只写凭证，不碰选中车**。
    ///
    /// 存储里那份可能已经被换过账号 / 换过选中车。用整份写回的话，同步只搬凭证、内存里的
    /// 选中车还是上一辆，等版本号追平就会把上一辆车原样写回去——界面读内存、其它入口读存储，
    /// 两边认成不同的车。所以这里以存储里那份为底，只把凭证字段盖上去。
    private fun persistTokens() = synchronized(lock) {
        current = current.copy(authRevision = System.currentTimeMillis())
        val latest = store.load()
        if (latest == null) {
            // 存储是空的（还没登录过），本实例手里这份就是唯一的一份。
            // 但读不出来也会走到这，那就什么都别写——理由同 `persist()`。
            if (current.deviceId.isEmpty()) {
                AuthAuditLog.note("跳过凭证落盘：本入口还没拿到 deviceId")
                return
            }
            store.save(current)
            return
        }
        val merged = merging(current, latest) ?: return
        store.save(merged)
    }

    /// 从存储里捞一次别处换发的凭证，采纳了返回 true。
    private fun syncAuthFromStore(): Boolean = synchronized(lock) { syncAuthLocked() }

    /// 只同步凭证本身（`oldAuth` / `newAuth` / `phone`）。车辆列表、选中车、路由不动——
    /// 那些是本实例正在用的界面状态。调用方必须已持有 `lock`。
    private fun syncAuthLocked(): Boolean {
        val stored = store.load() ?: return false
        adoptDeviceIdLocked(stored.deviceId)
        val mine = current.authRevision ?: 0
        val theirs = stored.authRevision ?: 0
        if (theirs <= mine) return false
        current = current.copy(
            oldAuth = stored.oldAuth,
            newAuth = stored.newAuth,
            phone = if (stored.phone.isNotEmpty()) stored.phone else current.phone,
            authRevision = theirs,
        )
        AuthAuditLog.note("采纳其它入口换发的凭证（revision $mine → $theirs）")
        return true
    }

    /// 把存储里那个 `deviceId` 对齐过来。**不看 `authRevision`**——设备号不随续期变，
    /// 它只有一个正确值：登录时上报给服务端、被服务端拿去绑 token 的那个。
    ///
    /// 这一步是「控车全废、只能重新登录」那个死结的关门处。原来的同步只搬凭证不搬设备号，
    /// 于是启动时存储读失败的入口会这样走：手里是一份空会话 → 同步把凭证搬进来 →
    /// 会话变成「有凭证」，`restoreSessionFromStore()` 的守卫从此永远为假，自愈路彻底关死
    /// → 设备号停在错的那个 → 老链路一律 `result=39` → 整份写回时再把它钉进存储。
    ///
    /// 现在 `fresh()` 留空设备号，这里再把真的那个补回来，两头一起把路堵死。
    /// 调用方必须已持有 `lock`。
    private fun adoptDeviceIdLocked(stored: String) {
        if (stored.isEmpty() || stored == current.deviceId) return
        val mine = current.deviceId
        current = current.copy(deviceId = stored)
        if (mine.isEmpty()) {
            AuthAuditLog.note("从存储补回 deviceId（本入口启动时读不到）")
        } else {
            // 走到这里说明本入口手里那个是凭空发的——正是上面说的死结。留痕。
            AuthAuditLog.note("deviceId 与存储不一致，已对齐到存储那份（本入口 ${tail(mine)} → ${tail(stored)}）")
        }
    }

    /// 设备号只在日志里留个尾巴，够对照就行。
    private fun tail(value: String): String = if (value.isEmpty()) "(空)" else "…" + value.takeLast(4)

    /// 从单独那条存储项把设备号读回来。读不到就保持空着，**绝不发新的**。
    private fun restoreDeviceIdFromStore(): Boolean {
        synchronized(lock) {
            if (current.deviceId.isNotEmpty()) return false
        }
        val stored = store.loadDeviceId() ?: return false
        synchronized(lock) {
            if (current.deviceId.isNotEmpty()) return false
            current = current.copy(deviceId = stored)
        }
        AuthAuditLog.note("从存储读回 deviceId")
        return true
    }

    /// 首次短信登录前给这台设备发一个设备号。**只有这一条路**能生成新设备号。
    ///
    /// 别处一律不发：换设备号会让老签名链路直接 `result=39`，而重新绑定只能靠重新登录。
    private fun ensureDeviceId() {
        restoreDeviceIdFromStore()
        val generated = synchronized(lock) {
            if (current.deviceId.isNotEmpty()) return
            LeapSession.randomDeviceId().also { current = current.copy(deviceId = it) }
        }
        // 立刻落盘：登录请求带的就是它，后面服务端拿它绑 token。这一步要是没写成，
        // 下次启动就成了「服务端记着一个设备号、本机手里另一个」——老链路全废。
        store.saveDeviceId(generated)
        AuthAuditLog.note("生成新的 deviceId（登录流程）")
    }

    /// 发请求前确认手里有设备号，没有就这次别发。
    ///
    /// 空设备号发出去，老链路一律 `result=39`（服务端按 deviceID 取它记录的 token 重算签名），
    /// 而 App 会把 39 当成「该刷新 token 了」——刷新永远成功、重试永远失败，
    /// 用户看到的就是「按什么都提示指令下发失败」。宁可这一次不发。
    private fun requireDeviceId() {
        restoreDeviceIdFromStore()
        if (current.deviceId.isNotEmpty()) return
        AuthAuditLog.note("拒绝在 deviceId 为空时发请求（存储仍读不到）")
        throw LeapError.server("设备信息暂时读不到，请解锁手机后重试")
    }

    // MARK: - 登录

    suspend fun sendSMS(phone: String) {
        // 登录链路是唯一允许发新设备号的地方，从发验证码这步就得有，
        // 后面 `oldAppHeaders()` 的 APPImei 要用它。
        ensureDeviceId()
        val cipher = LeapCrypto.phoneNoCiphertext(phone)
        val response = request(
            url = "${LeapConstants.APP_USER_HOST}/${LeapPaths.APP_USER}/applogin/compliance/sendmessagecode",
            method = "GET",
            headers = oldAppHeaders(includeToken = false),
            query = mapOf("phoneNo" to cipher),
        )
        assertSuccess(response, "验证码发送失败")
    }

    /// 短信验证码登录。
    ///
    /// 第一步先把本机会话清成干净态。这不是顺手做的清理，是这条链路能不能走通的前提：
    /// 被官方 App 挤下线后，本机手里那份 `oldAuth.token` 已经被服务端作废，而
    /// `oldAppHeaders()` 会把它当 `XFX-CDN-CROSS-NODE` 一起发出去——带着一个作废的 token
    /// 去打登录接口，验证码再对也会被拒。用户看到的就是「验证码是对的，但报登录异常」。
    ///
    /// 更糟的是它会自锁死：`oldAuth` 在换网关之前就赋了值，换网关那步一失败，内存里就留下
    /// 一份「有 oldAuth、没 newAuth」的半截会话，界面停在登录页，而清理逻辑的守卫看的正是
    /// `isLoggedIn`，于是一次都跑不了——用户怎么重试都是同一个脏 token 发出去。
    ///
    /// 保留 `deviceId`：换设备号会让老签名链路直接返回 result=39。
    suspend fun login(phone: String, smsCode: String) {
        // 直接进登录页（没走发验证码那步，比如别的设备上收到码）时这里才真的生成。
        ensureDeviceId()
        // 顺带把上一个账号的车辆列表、选中车和机房路由也清了：`loadVehicles()` 只在
        // selectedVin 为空时才设默认车，留着旧 VIN 车况请求就会一直打别人的车。
        val deviceId = current.deviceId
        synchronized(lock) { current = LeapSession.fresh().copy(deviceId = deviceId) }

        val params = mapOf(
            "phoneNoCiphertext" to LeapCrypto.phoneNoCiphertext(phone),
            "smsCode" to smsCode,
            "deviceID" to deviceId,
        )
        // 与 iOS / 鸿蒙同一条接口：官方 iOS 1.20.64 的 loginwithphone 用 POST_Form，三个参数放表单 body。
        // 不走 check_login_with_phone——那条要带第三方设备指纹（smDeviceId）。
        val response = request(
            url = "${LeapConstants.APP_USER_HOST}/${LeapPaths.APP_USER}/applogin/loginwithphone",
            method = "POST",
            headers = oldAppHeaders(includeToken = false),
            formBody = params,
        )
        assertSuccess(response, "验证码登录失败")

        val oldAuth = extractOldAuth(response)
        synchronized(lock) {
            current = current.copy(phone = phone.trim(), oldAuth = oldAuth)
        }
        try {
            exchangeNewGateway()
        } catch (e: Throwable) {
            // 换网关失败：把刚拿到的 oldAuth 丢掉，退回干净态再抛。
            // 留着它下一次登录就会带上，一次偶发失败会变成永久登不上。
            synchronized(lock) { current = LeapSession.fresh().copy(deviceId = deviceId) }
            throw e
        }
        persistAuth()
        AuthAuditLog.note("短信登录成功")
    }

    fun logout() {
        synchronized(lock) { current = LeapSession.fresh() }
        store.clear()
        OperationPasswordStore().clear()
        // TODO(P8)：蓝牙证书和快速重连 token 也要在这里整组清掉。
        // 退登也是一次凭证变更，且必须是最新的那次：别处可能正跑着一次拉取，
        // 它手里还是旧凭证，写回时得看到「退登比我新」才不会把人又装回登录态。
        persistAuth()
    }

    fun resetSession() {
        val deviceId = current.deviceId
        // 保留 deviceId：换设备号会让老签名链路直接返回 result=39。
        synchronized(lock) { current = LeapSession.fresh().copy(deviceId = deviceId) }
        store.clear()
        OperationPasswordStore().clear()
        persistAuth()
    }

    /// 用老 token 换新网关的 accessToken / signKey。
    private suspend fun exchangeNewGateway() {
        val oldAuth = current.oldAuth ?: throw LeapError.notLoggedIn()
        val body = mapOf(
            "identifier" to oldAuth.accountId,
            "identifierType" to "1",
            "security" to oldAuth.token,
        )
        val response = request(
            url = "${LeapConstants.GLOBAL_HOST}/base/${LeapPaths.BASE_USER}/account/v1/login",
            method = "POST",
            headers = newGatewayHeaders(body, needLogin = false),
            jsonBody = body,
        )
        assertSuccess(response, "新网关换取 token 失败")
        val newAuth = extractNewAuth(response, oldAuth)
        synchronized(lock) { current = current.copy(newAuth = newAuth) }
        persistTokens()
    }

    // MARK: - Token 续期

    /// 续期期间进来的请求先在这儿排一下队，等换发完再带着新凭证出门。
    ///
    /// 对齐官方的 `CacheRequestManager`：官方在刷新 token 期间把后来的请求整队缓存住，
    /// 刷新完拿新 token 重放。我们原来是「照发不误 → 拿旧 token 撞 401/39 → 各自再触发
    /// 一次重试」，多打的那几发全是注定失败的，还平白抬高服务端看到的鉴权失败频次
    /// （老链路的 39 更是会被风控盯上）。
    ///
    /// 只等、不发起，也不把续期的错误扣到这条请求头上：等完照发，成不成由它自己那套
    /// 判据（401 重试、39 冷却窗口、连败升级）说了算。
    ///
    /// 续期自身那几发请求走的是 `request(...)`，不经过这道闸，所以不会自等自——
    /// `Mutex` 不可重入，这一点必须一直成立。
    private suspend fun awaitOngoingRefresh() {
        if (!refreshMutex.isLocked) return
        AuthAuditLog.note("请求撞上正在进行的续期，先排队等换发完成")
        refreshMutex.withLock { }
    }

    /// 并发调用只跑一次续期：等锁期间别人已经换发过的，直接用它那份。
    /// refreshToken 每换发一次旧的就作废，这里再换一次等于把它那份也作废掉。
    suspend fun refreshAccessToken() {
        if (syncAuthFromStore()) return
        val before = current.newAuth?.accessToken.orEmpty()
        refreshMutex.withLock {
            if (syncAuthFromStore()) return
            if (current.newAuth?.accessToken.orEmpty() != before) return
            performAccessTokenRefresh()
        }
    }

    private suspend fun performAccessTokenRefresh() {
        val newAuth = current.newAuth
        if (newAuth == null || newAuth.refreshToken.isEmpty()) throw LeapError.sessionExpired()
        val body = mapOf("refreshToken" to newAuth.refreshToken)
        val response = request(
            url = "${LeapConstants.GLOBAL_HOST}/base/${LeapPaths.BASE_USER}/token/v1/refresh",
            method = "POST",
            headers = newGatewayHeaders(body, needLogin = true),
            jsonBody = body,
        )
        if (!response.isSuccess) {
            // 只有服务端明确说鉴权不过，才算登录态没了。限流、系统繁忙、字段改名都会走到这里，
            // 把它们一律当失效就是无缘无故把用户踢回登录页。
            if (isNewAuthFailure(response)) {
                if (syncAuthFromStore()) {
                    AuthAuditLog.note("新链路续期被拒，但别处已换发更新的凭证，采纳后继续")
                    return
                }
                // 官方在这一步不会退登：refreshToken 被拒时，用老 token 静默重走一次
                // `account/v1/login` 把新网关凭证整份换回来（官方 `PublicUtils.reLogin`
                // → `LoginManager`，和这里的 `exchangeNewGateway()` 是同一个接口）。
                // 新网关那份本来就是从老 token 派生的，老 token 还活着就没有任何理由
                // 把人踢回登录页。
                if (current.oldAuth?.token.orEmpty().isNotEmpty()) {
                    try {
                        exchangeNewGateway()
                        AuthAuditLog.note("新链路续期被拒，已用老 token 静默重换新网关凭证")
                        return
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        // 断网不算失效，原样抛回去让上层当网络错误处理。
                        if ((e as? LeapError)?.kind == LeapErrorKind.Network) throw e
                        AuthAuditLog.note("新链路续期被拒后静默重换也失败：${LeapError.messageOf(e)}")
                    }
                }
                AuthAuditLog.note("新链路续期被服务端拒绝：${response.responseMessage}")
                throw LeapError.sessionExpired()
            }
            val message = response.responseMessage
            throw LeapError.server(message.ifEmpty { "登录续期失败" })
        }
        val refreshed = extractNewAuth(response, current.oldAuth)
        synchronized(lock) { current = current.copy(newAuth = refreshed) }
        persistTokens()
    }

    suspend fun refreshOldToken() {
        if (syncAuthFromStore()) return
        val before = current.oldAuth?.token.orEmpty()
        refreshMutex.withLock {
            if (syncAuthFromStore()) return
            if (current.oldAuth?.token.orEmpty() != before) return
            performOldTokenRefresh()
        }
    }

    /// 老 token 续期：GET /app-user/appuseroperate/getnewtoken。
    /// refreshToken 参与签名但不出现在 query 里，只放在 `XFX-CDN-CROSS-REFRESH-NODE` 头。
    private suspend fun performOldTokenRefresh() {
        val session = current
        val oldAuth = session.oldAuth
        if (oldAuth == null || oldAuth.refreshToken.isEmpty()) throw LeapError.sessionExpired()
        if (session.phone.isEmpty()) {
            // 本机会话缺了手机号，续期签不出来。这是本地数据问题，不是服务端说登录态没了——
            // 当前 token 只要还没到期就照常能用，不该借机把人踢回登录页。
            throw LeapError.server("本地登录信息不完整，暂时无法续期")
        }
        val accountNumber = LeapCrypto.phoneNoCiphertext(session.phone)
        val map = linkedMapOf(
            "timespan" to System.currentTimeMillis().toString(),
            "nonce" to LeapCrypto.randomNonce(),
            "deviceID" to session.deviceId,
            "refreshtoken" to oldAuth.refreshToken,
            "accountId" to oldAuth.accountId,
            "accountNumber" to accountNumber,
        )
        val signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map))
        map.remove("refreshtoken")
        map["signStr"] = signStr

        val headers = oldAppHeaders().toMutableMap()
        headers[LeapHeaders.XFX_CROSS_REFRESH_NODE] = oldAuth.refreshToken

        val response = request(
            url = "${LeapConstants.APP_USER_HOST}/${LeapPaths.APP_USER}/appuseroperate/getnewtoken",
            method = "GET",
            headers = headers,
            query = map,
        )
        val data = response.get("data") ?: response
        val token = data.get("token")?.stringValue
        if (token.isNullOrEmpty() || !response.isSuccess) {
            // refreshToken 被服务端明确拒了，救不回来，只能重新短信登录。
            if (isOldAuthFailure(response)) {
                if (syncAuthFromStore()) {
                    AuthAuditLog.note("老链路续期被拒，但别处已换发更新的凭证，采纳后继续")
                    return
                }
                AuthAuditLog.note(
                    "老链路续期被服务端拒绝：result=${response.get("result")?.stringValue ?: "?"} ${response.responseMessage}",
                )
                throw LeapError.sessionExpired()
            }
            // 其余情况——限流、系统繁忙、响应结构变了——都不是登录态的事。
            // 一律抛 sessionExpired 的话，服务端抖一下用户就被踢回登录页了。
            val message = response.responseMessage
            throw LeapError.server(message.ifEmpty { "登录续期失败" })
        }
        val expiredSeconds = data.get("tokenExpired")?.stringValue?.toDoubleOrNull() ?: 21600.0
        val now = System.currentTimeMillis()
        val refreshed = OldAuth(
            accountId = oldAuth.accountId,
            token = token,
            refreshToken = data.get("refreshToken")?.stringValue ?: oldAuth.refreshToken,
            nickname = oldAuth.nickname,
            tokenExpired = expiredSeconds.toLong().toString(),
            tokenObtainedAt = now,
            tokenExpiresAt = now + (expiredSeconds * 1000).toLong(),
        )
        synchronized(lock) { current = current.copy(oldAuth = refreshed) }
        persistTokens()
        // 新网关凭证绑定在老 token 上，续期后需要重新交换。
        // 换不成不影响这次续期的结果（老链路已经好了），但新网关那份会一直用旧的、
        // 直到 401 再走一次续期——所以失败要留痕，否则这条路是全静默的。
        try {
            exchangeNewGateway()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            DiagLog.note("[auth] 老 token 续期后重换新网关凭证失败：${LeapError.messageOf(e)}")
        }
    }

    /// 老链路请求 + `result=39` 自愈。对齐官方零跑 App 的做法：39 只当「这份 token 该刷新了」，
    /// 不当「登录态没了」。官方对国内 39 一律走刷新后重试，只有网关级 refreshToken 过期码才重登，
    /// 所以官方几乎不会莫名退登。
    ///
    /// - A：刷新后重试仍是 39，**不再抛 `sessionExpired`**（不清会话、不回登录页），改抛瞬时业务错误。
    ///   服务端在刚续期后的短窗口里对老链路回一两次 39 是常见抖动，把它升级成退登正是
    ///   「登录约 77 分钟后莫名掉登录」的直接根因。真正的失效仍由 `refreshOldToken` 内部
    ///   refreshToken 被拒兜底。
    /// - B：冷却窗口——老 token 是 `OLD_TOKEN_REAUTH_COOLDOWN` 秒内换发的，再收到 39 就**不刷新**，
    ///   先采纳可能更新的凭证再重试一次，仍失败当瞬时错误。避免一次续期后紧跟的 39 触发第二次
    ///   续期（旧 refreshToken 立刻作废，反而制造失效窗口），对齐官方 60 秒闸。
    private suspend fun oldAuthedRequest(
        transientFailureMessage: String,
        perform: suspend () -> JsonValue,
    ): JsonValue {
        // 正在换发凭证就先等着，别拿一个马上要作废的 token 出门。
        awaitOngoingRefresh()
        var response = perform()
        if (!isOldAuthFailure(response)) {
            oldAuthFailureStreak = 0
            return response
        }

        if (recentlyRefreshedOldToken()) {
            // B：冷却窗口内不再续期。别处可能已换发，先采纳再重试一次。
            syncAuthFromStore()
            AuthAuditLog.note("老链路 result=39 命中续期冷却窗口，跳过刷新直接重试")
            response = perform()
            if (!isOldAuthFailure(response)) {
                oldAuthFailureStreak = 0
                return response
            }
            // A：仍是 39，当瞬时错误，不退登。
            AuthAuditLog.note("老链路冷却窗口内重试仍 result=39，按瞬时错误处理，不退登")
            throw noteOldAuthFailure(transientFailureMessage)
        }

        refreshOldToken()
        response = perform()
        if (isOldAuthFailure(response)) {
            // A：刷新后仍 39，不再判定登录失效——这正是官方不会退登的场景。
            AuthAuditLog.note("老链路刷新后仍 result=39，按瞬时错误处理，不退登")
            throw noteOldAuthFailure(transientFailureMessage)
        }
        oldAuthFailureStreak = 0
        return response
    }

    /// 老链路连续被判「信息校验失败」（result=39）的次数，以及这串连败是从什么时候开始的。
    private var oldAuthFailureStreak = 0
    private var oldAuthFailureStreakStartedAt = 0L

    /// 记一次「刷新过还是 39」，并决定这次该抛哪种错。
    ///
    /// 修 A 把 39 从「退登」降成了「瞬时错误」，但只降了一半：真的救不回来时
    /// （本机设备号和服务端记的对不上、token 被别处顶掉），用户会永远看到
    /// 「请稍后重试」，而重试一万次也不会好——他实际需要做的是重新登录，却没人告诉他。
    /// 这里补上那一半：连败次数够、且这串连败跨过了足够长的时间，才升级成
    /// `NeedsRelogin`（只提示，不清会话、不清蓝牙钥匙证书）。
    ///
    /// 两个条件都要满足是刻意的——服务端抖动是以秒计的，连着三次都在几秒内发生
    /// 只能说明用户手快，跨过 5 分钟仍每次都失败才叫「不会自己好」。
    private fun noteOldAuthFailure(transientFailureMessage: String): Throwable {
        val now = System.currentTimeMillis()
        if (oldAuthFailureStreak == 0) oldAuthFailureStreakStartedAt = now
        oldAuthFailureStreak += 1
        val spanned = (now - oldAuthFailureStreakStartedAt) / 1000
        if (!shouldEscalateOldAuthFailure(oldAuthFailureStreak, spanned)) {
            return LeapError.server(transientFailureMessage)
        }
        AuthAuditLog.note("老链路连续 $oldAuthFailureStreak 次 result=39、已持续 $spanned 秒，提示重新登录")
        return LeapError.needsRelogin()
    }

    /// 老 token 是否在续期冷却窗口内换发（含登录时初次取得）。`tokenObtainedAt` 是毫秒。
    private fun recentlyRefreshedOldToken(): Boolean {
        val obtainedAt = current.oldAuth?.tokenObtainedAt ?: 0
        if (obtainedAt <= 0) return false
        val age = (System.currentTimeMillis() - obtainedAt) / 1000.0
        return age >= 0 && age < LeapConstants.OLD_TOKEN_REAUTH_COOLDOWN
    }

    private suspend fun ensureFreshAccessToken() {
        // 先认一次别处换发的凭证：这个实例常驻，内存里那份可能是几小时前的，
        // 拿它去请求必然 401，再拿它的 refreshToken 去续期就是拿作废的换。
        syncAuthFromStore()
        val expiry = current.newAuth?.expiresAt ?: 0
        if (expiry <= 0) return
        if (expiry - System.currentTimeMillis() <= LeapConstants.ACCESS_TOKEN_LEEWAY * 1000) {
            refreshAccessToken()
        }
    }

    private suspend fun ensureFreshOldToken() {
        syncAuthFromStore()
        val expiry = current.oldAuth?.tokenExpiresAt ?: 0
        if (expiry <= 0) return
        if (expiry - System.currentTimeMillis() <= LeapConstants.OLD_TOKEN_LEEWAY * 1000) {
            // 续不上不算致命：当前 token 多半还能再用一会儿，真不行下游会收到 39 再走自愈。
            try {
                refreshOldToken()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                DiagLog.note("[auth] 老 token 预续期失败：${LeapError.messageOf(e)}")
            }
        }
    }

    /// 主动校验登录态。开 App、回前台时调用。
    ///
    /// 车况刷新走的是新网关读取 token——被别的设备挤下线后它仍然活着，所以刷新永远探不到失效
    /// （用户「还能看到页面」正是这个原因）。真正会被服务端作废的是老链路那条控车 token。
    /// 这里主动对它做一次续期探测：`refreshToken` 被服务端拒 = 登录态没了；网络等其它错误照原样
    /// 抛出，**不**当作失效——弱网不该把人误踢下线。
    ///
    /// 但探测不能每次开 App 都真打一次：老 token 服务端给的是 6 小时，每探一次就换发一次、
    /// 旧 refreshToken 立刻作废。所以刚换发过的就直接认有效——那次换发本身就是服务端对这份
    /// 登录态的确认，比再问一遍更可信也更便宜。
    suspend fun validateSession() {
        syncAuthFromStore()
        val oldAuth = current.oldAuth ?: throw LeapError.sessionExpired()
        val obtainedAt = oldAuth.tokenObtainedAt
        val age = (System.currentTimeMillis() - obtainedAt) / 1000.0
        if (obtainedAt > 0 && age >= 0 && age < LeapConstants.SESSION_PROBE_FRESHNESS) return
        refreshOldToken()
    }

    // MARK: - 车辆

    suspend fun loadVehicles(): List<Vehicle> {
        val response = newGatewayRequest(
            url = "${LeapConstants.GLOBAL_HOST}/app/${LeapPaths.APP_GLOBAL}/v1/vehicle/list",
            method = "GET",
            params = emptyMap(),
        )
        // 诊断：在 assertSuccess 之前打，否则接口报错时这份响应就看不到了。
        DiagLog.emit("vehicle-list", DiagLog.redacted(response).prettyPrinted)
        assertSuccess(response, "获取车辆列表失败")

        val seen = mutableSetOf<String>()
        val vehicles = mutableListOf<Vehicle>()
        for (obj in response.allObjects { (it["vin"]?.stringValue?.length ?: 0) >= 8 }) {
            val vin = obj["vin"]?.stringValue ?: continue
            if (!seen.add(vin)) continue
            val carType = obj["carType"]?.stringValue ?: obj["cartype"]?.stringValue ?: ""
            // 车名优先取车主起的 `vinNickname`，没有就退到车型别名 `carAlias`；
            // 两个都空再兜到 carType，最后到「我的车」，避免空串。
            val name = obj["vinNickname"]?.stringValue
                ?: obj["carAlias"]?.stringValue
                ?: carType.ifEmpty { "我的车" }
            // 能力码全在 abilities 数组里（服务器原始短码 "1".."89"）。增程判据看含不含 "39"。
            val abilities = obj["abilities"]?.arrayValue?.mapNotNull { it.stringValue } ?: emptyList()
            val isExtendRange = abilities.contains("39")
            // 哨兵/遮阳帘/天窗/前备箱走的是内部码（400/240/300/131），但 vehicle/list **没有**
            // permission 字段——原始码经 CarPerManager 那张表翻成内部码才对得上。此前直接读
            // object["permission"] 恒空，四个支持位对所有真实用户全判假。为兼容「万一某网关真回
            // permission」仍保留兜底，与翻译结果合并去重。
            val permission = VehicleUtil.permissionCodes(abilities).toMutableList()
            val literal: List<String> = obj["permission"]?.arrayValue?.mapNotNull { it.stringValue }
                ?: obj["permission"]?.stringValue?.takeIf { it.isNotEmpty() }
                    ?.split(",")?.map { it.trim() }
                ?: emptyList()
            for (code in literal) if (!permission.contains(code)) permission.add(code)
            vehicles.add(
                Vehicle(
                    vin = vin,
                    carType = carType,
                    name = name,
                    isExtendRange = isExtendRange,
                    permission = permission,
                    isSentinelSupported = Vehicle.supportsSentinel(carType, permission),
                ),
            )
        }
        DiagLog.note(
            "[vehicle-list] 解析出 ${vehicles.size} 辆：" + vehicles.joinToString(" | ") {
                "${DiagLog.maskVin(it.vin)} carType=${it.carType.ifEmpty { "(空)" }}" +
                    " name=${it.name} 增程=${it.isExtendRange} 哨兵=${it.isSentinelSupported}"
            },
        )
        synchronized(lock) {
            current = current.copy(vehicles = vehicles)
            val first = vehicles.firstOrNull()
            if (current.selectedVin.isEmpty() && first != null) {
                current = current.copy(
                    selectedVin = first.vin,
                    selectedCarType = first.carType,
                    route = null,
                )
            }
        }
        persist()
        return vehicles
    }

    fun selectVehicle(vin: String, carType: String = "") {
        synchronized(lock) {
            val vehicle = current.vehicles.firstOrNull { it.vin == vin }
            current = current.copy(
                selectedVin = vin,
                selectedCarType = carType.ifEmpty { vehicle?.carType ?: "" },
                // 别名是上一台车的，留着别处会顶着旧车名，等新车资源就位再重新推。
                selectedCarAlias = null,
                route = null,
            )
            // 充电配置缓存跟着 VIN 走，切车即失效（fetchVehicleState 还会按 VIN 再兜一次）。
            commonConfigCacheVin = null
            cachedChargePlan = null
            cachedChargePlanLimit = null
        }
        persist()
    }

    /// 记下从车模资源目录反推出来的车型别名，给界面显示用。
    fun rememberCarAlias(alias: String?) {
        synchronized(lock) {
            if (current.selectedCarAlias == alias) return
            current = current.copy(selectedCarAlias = alias)
        }
        persist()
    }

    /// 车辆所在区域，决定车况 / 远控请求打到哪个机房。
    private suspend fun ensureRoute(): VehicleRoute {
        val vin = current.selectedVin
        if (vin.isEmpty()) throw LeapError.missingVehicle()
        current.route?.let { if (it.appRegion.isNotEmpty()) return it }

        val params = mapOf("vin" to vin)
        val response = newGatewayRequest(
            url = "${LeapConstants.GLOBAL_HOST}/app/${LeapPaths.APP_GLOBAL}/v1/vehicle/getCarRoute",
            method = "GET",
            params = params,
            query = params,
        )
        assertSuccess(response, "获取车辆路由失败")
        val node = response.get("data")?.objectValue
            ?: response.firstObject { it["appRegion"] != null || it["appCenter"] != null }
        val route = VehicleRoute(
            appRegion = (node?.get("appRegion")?.stringValue ?: "").trimTrailingSlash(),
            appCenter = (node?.get("appCenter")?.stringValue ?: "").trimTrailingSlash(),
        )
        DiagLog.note(
            "[route] vin=${DiagLog.maskVin(vin)}" +
                " appRegion=${route.appRegion.ifEmpty { "(空)" }}" +
                " appCenter=${route.appCenter.ifEmpty { "(空)" }}",
        )
        if (route.appRegion.isEmpty()) throw LeapError.server("车辆路由缺少 appRegion")
        synchronized(lock) { current = current.copy(route = route) }
        persist()
        return route
    }

    /// @param refreshConfig 是否强制重拉 commonConfig（充电上限 / 充电计划）。
    ///        下拉 / 手动刷新传 `true`；轮询保持默认 `false`，走按 VIN 的缓存。
    suspend fun fetchVehicleState(refreshConfig: Boolean = false): VehicleState {
        val route = ensureRoute()
        val vin = current.selectedVin
        val carType = current.selectedCarType
        val body = mapOf("vin" to vin)
        val response = newGatewayRequest(
            url = "${route.appRegion}/app/${LeapPaths.APP_SIGNAL}/signal/info/query",
            method = "POST",
            params = body,
            jsonBody = body,
        )
        DiagLog.note(
            "[state] vin=${DiagLog.maskVin(vin)} carType=${carType.ifEmpty { "(空)" }}" +
                " code=${response.responseCode ?: "nil"}" +
                " msg=${response.responseMessage.ifEmpty { "(空)" }}",
        )
        assertSuccess(response, "获取车况失败")

        val container = response.firstObject { it["signalMap"]?.objectValue != null }
        val signalNode = container?.get("signalMap")
            ?: response.path("data", "signalMap")
            ?: response.get("signalMap")
        val map = signalNode?.objectValue ?: run {
            // 找不到 signalMap 时，完整响应是唯一线索——新车型可能换了外层结构。
            DiagLog.emit("state-raw", DiagLog.redacted(response).prettyPrinted)
            throw LeapError.decode("车况响应里没有 signalMap")
        }
        val signalMap = map.mapNotNull { (key, value) -> value.stringValue?.let { key to it } }.toMap()

        synchronized(lock) {
            if (commonConfigCacheVin != vin || commonConfigAccount != current.oldAuth?.accountId) {
                commonConfigCacheVin = null
                cachedChargePlan = null
                cachedChargePlanLimit = null
            }
        }
        val needsConfig = synchronized(lock) {
            refreshConfig || commonConfigCacheVin == null || System.currentTimeMillis() - commonConfigFetchedAt >= 15_000
        }
        if (needsConfig) {
            try {
                refreshChargePlan()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                // 配置读取失败不阻断普通车况，也不延长缓存有效期。
            }
        }

        val state = VehicleState(
            signalMap = signalMap,
            // 车型不同，上报的字段命名体系也不同，按上报内容自己判断该用哪套表，
            // 再叠上车主自己标定出来的映射。
            schema = SignalSchema.detect(signalMap, carType).merging(LearnedSignals.keys(carType)),
            collectedAt = System.currentTimeMillis(),
            chargePlanLimit = cachedChargePlanLimit,
            chargePlan = cachedChargePlan,
            // 是不是增程车由 vehicle/list 的 abilities 决定，车况响应里没有，从选中车注入；
            // 匹配不到（会话里还没这辆车）就保持 false。下游油量显示全看这个开关。
            isExtendRange = current.selectedVehicle?.isExtendRange ?: false,
        )
        DiagLog.emit(
            "signalmap",
            "体系=${state.schema.id} 共 ${map.size} 个字段，取到字符串值 ${signalMap.size} 个\n" +
                signalMap.keys.sorted().joinToString("\n") { "$it = ${signalMap[it]}" },
        )
        // 值是对象/数组的字段会在上面被整个丢掉，字段名单独留一份——万一某个车型的
        // signalMap 是嵌套结构，state 会是空的，而这里正好能看出来。
        val dropped = map.keys.filter { signalMap[it] == null }.sorted()
        if (dropped.isNotEmpty()) {
            DiagLog.emit("signalmap-dropped", "非字符串值的字段 ${dropped.size} 个：" + dropped.joinToString(", "))
        }
        return state
    }

    /// 独立重读计划，不受车况轮询的 fetchInFlight 限制。
    suspend fun refreshChargePlan(): ChargePlan? {
        val scope = synchronized(lock) {
            Triple(current.selectedVin, current.oldAuth?.accountId, ++commonConfigRequest)
        }
        val config = fetchCommonConfig()
        return synchronized(lock) {
            if (scope.first != current.selectedVin || scope.second != current.oldAuth?.accountId ||
                scope.third != commonConfigRequest) throw LeapError.server("车辆或配置请求已更新，请重试")
            val plan = VehicleState.chargePlanFromConfig(config)
            cachedChargePlan = plan
            cachedChargePlanLimit = plan?.percent
            commonConfigCacheVin = scope.first
            commonConfigAccount = scope.second
            commonConfigFetchedAt = System.currentTimeMillis()
            plan
        }
    }

    /// 拉 commonConfig（车辆公共配置），返回里面的 `data.config` 对象。
    ///
    /// 充电计划就在这张表的 `config."3"` 里——车况响应里没有，官方也是另发这个接口拿的。
    /// 走老签名 GET，host 与预约端点一致取 `appCenter ?: appRegion`。
    ///
    /// 返回 config 节点（可能为 null：某些车型 / 版本不带）。调用方兜底，拉失败或没有 config
    /// 都不该影响车况本身。
    suspend fun fetchCommonConfig(): JsonValue? {
        val route = ensureRoute()
        ensureFreshOldToken()
        val host = route.appCenter.ifEmpty { route.appRegion }
        val query = oldSignedParams(
            mapOf(
                "appVersion" to current.appVersion,
                "osType" to "Android",
                "vin" to current.selectedVin,
            ),
        )
        val response = request(
            url = "$host/${LeapPaths.CAROWNER}/v3/api/vehicleinfo/commonConfig",
            method = "GET",
            headers = oldAppHeaders(),
            query = query,
        )
        assertSuccess(response, "获取车辆配置失败")
        return response.path("data", "config")
    }

    // MARK: - 里程能耗统计

    /// 一次拉齐几个 drivingrecord 接口，揉成规范化统计。
    ///
    /// - `mileage/energy/detail` 用 `vin`，且必须带 `begintime`+`endtime`，否则只回退化字段。
    /// - 能耗接口用 `carvin`；`getLastweekEC` 也要时间范围（返回的是能耗构成饼图）。
    /// 任一接口失败 / 该车不返回不影响其它块，缺的置 null。
    suspend fun fetchDrivingStats(range: DrivingStatsRange? = null): DrivingStats = coroutineScope {
        val route = ensureRoute()
        ensureFreshOldToken()
        val hosts = listOf(LeapConstants.GLOBAL_HOST, route.appCenter, route.appRegion)
            .filter { it.isNotEmpty() }.distinct()
        val window = range ?: DrivingStatsRange.lastSevenDays()
        val vin = current.selectedVin
        val timeParams = mapOf(
            "begintime" to window.begintime.toString(),
            "endtime" to window.endtime.toString(),
        )

        val mileage = async {
            oldDrivingRecord("mileage/energy/detail", mapOf("vin" to vin) + timeParams, hosts)
        }
        val weeklyRaw = oldDrivingRecord("getLastNweeks100kmECAndRank", mapOf("carvin" to vin), hosts)

        // 能耗构成默认跟着「本周」那根柱子走（和官方一致），可它的区间要等周列表回来才知道，
        // 所以这一发只能串在周列表后面——总请求数没变，只多一个来回。
        // 周列表拉不到就退回 window（近 7 天）并把 distributionWeekID 留空，界面据此改口。
        val lastWeek = (weeklyRaw?.path("data", "weeklyEC")?.arrayValue ?: emptyList()).lastOrNull()
            ?.let {
                DrivingStats.WeeklyEC(
                    weekStart = it.get("weekStart")?.stringValue,
                    weekEnd = it.get("weekEnd")?.stringValue,
                    hundredKmEc = null,
                )
            }
        val distributionRaw = fetchEnergyDistributionRaw(vin, lastWeek?.range ?: window, hosts)

        DrivingStats.from(
            mileageRaw = mileage.await(),
            distributionRaw = distributionRaw,
            weeklyRaw = weeklyRaw,
            range = window,
            distributionWeekID = if (lastWeek?.range == null) null else lastWeek.id,
        )
    }

    /// 单独拉某个区间的能耗构成（`getLastweekEC`）。页面点周柱子时按周调，
    /// 拿不到就返回 null——调用方按「这周没数据」处理，不许拿别的区间顶。
    suspend fun fetchEnergyDistribution(range: DrivingStatsRange): DrivingStats.EnergyDistribution? {
        val route = ensureRoute()
        ensureFreshOldToken()
        val hosts = listOf(LeapConstants.GLOBAL_HOST, route.appCenter, route.appRegion)
            .filter { it.isNotEmpty() }.distinct()
        val raw = fetchEnergyDistributionRaw(current.selectedVin, range, hosts)
        return DrivingStats.EnergyDistribution.fromRaw(raw)
    }

    private suspend fun fetchEnergyDistributionRaw(
        vin: String,
        range: DrivingStatsRange,
        hosts: List<String>,
    ): JsonValue? = oldDrivingRecord(
        "getLastweekEC",
        mapOf(
            "carvin" to vin,
            // 时间戳收**秒**，不是毫秒。同一个 drivingrecord 命名空间下 mileage/energy/detail
            // 收的是毫秒，唯独这个接口收秒——传毫秒不报「参数越界」也不返空，而是被网关判成
            // `code:2 请求参数含非法字符`，看着像签名或字符集问题，实际只是量纲错了。
            "begintime" to range.begintimeSeconds.toString(),
            "endtime" to range.endtimeSeconds.toString(),
        ),
        hosts,
    )

    /// 老签名 GET 一个 drivingrecord 接口，按 host 依次 fallback（global 常 404，落到路由 host）。
    /// 失败 / 非成功响应返回 null，交给上层揉数据时按缺失处理。
    private suspend fun oldDrivingRecord(
        path: String,
        params: Map<String, String>,
        hosts: List<String>,
    ): JsonValue? {
        for (host in hosts) {
            try {
                val response = request(
                    url = "$host/${LeapPaths.CAROWNER}/v3/api/drivingrecord/$path",
                    method = "GET",
                    headers = oldAppHeaders(),
                    query = oldSignedParams(params),
                )
                if (response.isSuccess) return response
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                continue
            }
        }
        return null
    }

    // MARK: - 蓝牙钥匙

    /// 从官方 `syncBluetoothKeys` 接口同步当前车辆的蓝牙认证证书。
    /// 返回值含 ECDH/签名材料，调用方只能写进加密存储，不能进普通诊断日志。
    suspend fun fetchBLEKeyCertificate(): LeapBLEKeyCertificate {
        if (current.selectedVin.isEmpty()) throw LeapError.missingVehicle()
        if (current.oldAuth == null) throw LeapError.notLoggedIn()
        ensureFreshOldToken()
        val route = ensureRoute()
        if (route.appCenter.isEmpty()) throw LeapError.server("车辆中心路由为空")

        val response = oldAuthedRequest("蓝牙钥匙证书同步失败，请稍后重试") {
            request(
                url = "${route.appCenter}/${LeapPaths.CAROWNER}/v3/api/bluetoothkey/combine/syncBluetoothKeys",
                method = "POST",
                headers = oldAppHeaders(),
                formBody = oldSignedParams(mapOf("vin" to current.selectedVin)),
            )
        }
        assertSuccess(response, "蓝牙钥匙证书同步失败")
        val certificate = LeapBLEKeyCertificate.from(response)
            ?: throw LeapError.decode("蓝牙钥匙响应缺少 bluetoothKey")
        if (certificate.vin.isNotEmpty() && certificate.vin != current.selectedVin) {
            throw LeapError.decode("蓝牙钥匙证书 VIN 不匹配")
        }
        try {
            certificate.validatePasswordCard()
        } catch (e: LeapBLEProtocolError) {
            throw LeapError.decode(e.message)
        }
        DiagLog.note("[ble:certificate] 同步成功 keyType=${certificate.keyType} fingerprint=${certificate.fingerprint}")
        return certificate
    }

    // MARK: - 驻车照片

    /// 读取车辆驻车时自动上传的最近一张照片，不向车辆发送拍照指令。
    suspend fun fetchParkingPhoto(): ParkingPhoto {
        if (current.selectedVin.isEmpty()) throw LeapError.missingVehicle()
        if (current.oldAuth == null) throw LeapError.notLoggedIn()
        val response = oldSignedGETWithFallback(
            path = "chassis/query",
            params = mapOf("vin" to current.selectedVin),
            preferredHosts = listOf(LeapConstants.GLOBAL_HOST),
        )
        assertSuccess(response, "驻车照片查询失败")
        return ParkingPhoto.fromResponse(response)
    }

    /// 图片地址由业务接口直接返回，不追加旧网关签名或登录凭证。
    ///
    /// 与 iOS 的差异：那边用 `mimeType` 判「返回的是不是图片」，OkHttp 这层已经把响应头
    /// 收进 `download` 里丢掉了，这里改用魔数判。魔数其实更准——鉴权失败时服务端回的是
    /// JSON 错误体，Content-Type 却常常还写着 image/jpeg。
    suspend fun downloadParkingPhoto(url: String): ByteArray {
        if (!url.lowercase().startsWith("https://")) {
            throw LeapError.server("驻车照片地址不是安全连接")
        }
        val data = HttpTransport.download(url) ?: throw LeapError.server("驻车照片下载失败")
        if (data.isEmpty()) throw LeapError.decode("驻车照片内容为空")
        if (!looksLikeImage(data)) throw LeapError.decode("驻车照片返回了非图片内容")
        return data
    }

    /// JPEG / PNG / GIF / WebP / HEIC 的魔数。认不出的一律当非图片。
    private fun looksLikeImage(data: ByteArray): Boolean {
        fun at(index: Int): Int = if (index < data.size) data[index].toInt() and 0xff else -1
        return when {
            at(0) == 0xff && at(1) == 0xd8 -> true                                  // JPEG
            at(0) == 0x89 && at(1) == 0x50 && at(2) == 0x4e && at(3) == 0x47 -> true // PNG
            at(0) == 0x47 && at(1) == 0x49 && at(2) == 0x46 -> true                 // GIF
            at(0) == 0x52 && at(1) == 0x49 && at(2) == 0x46 && at(3) == 0x46 -> true // RIFF/WebP
            at(4) == 0x66 && at(5) == 0x74 && at(6) == 0x79 && at(7) == 0x70 -> true // ftyp/HEIC
            else -> false
        }
    }

    /// 老签名 GET：鉴权失败时刷新一次 token，并按 global / appRegion / appCenter 回退。
    private suspend fun oldSignedGETWithFallback(
        path: String,
        params: Map<String, String>,
        preferredHosts: List<String> = emptyList(),
    ): JsonValue {
        ensureFreshOldToken()
        val route = ensureRoute()
        val hosts = (preferredHosts + listOf(LeapConstants.GLOBAL_HOST, route.appRegion, route.appCenter))
            .filter { it.isNotEmpty() }.distinct()
        var lastError: Throwable? = null

        for (host in hosts) {
            try {
                val url = "$host/${LeapPaths.CAROWNER}/v3/api/$path"
                val response = oldAuthedRequest("接口返回失败，请稍后重试") {
                    request(
                        url = url,
                        method = "GET",
                        headers = oldAppHeaders(),
                        query = oldSignedParams(params),
                    )
                }
                if (response.isSuccess) return response
                lastError = LeapError.server(response.responseMessage.ifEmpty { "接口返回失败" })
            } catch (e: CancellationException) {
                throw e
            } catch (e: LeapError) {
                if (e.kind == LeapErrorKind.SessionExpired) throw e
                lastError = e
            } catch (e: Throwable) {
                lastError = e
            }
        }
        throw lastError ?: LeapError.server("请求失败")
    }

    // MARK: - 远控

    /// 发送远控指令，返回服务端回执里的 msgID。
    suspend fun sendControl(command: LeapCommand, operationPassword: String): ControlReceipt {
        if (current.selectedVin.isEmpty()) throw LeapError.missingVehicle()
        val oldAuth = current.oldAuth ?: throw LeapError.notLoggedIn()
        if (command.requiresOperationPassword && operationPassword.isEmpty()) {
            throw LeapError.server("该指令需要操作密码")
        }
        ensureFreshOldToken()
        val route = ensureRoute()
        // 预约类命令是另一套端点，且优先打 appCenter。
        val url = if (command.isAppointment) {
            val host = route.appCenter.ifEmpty { route.appRegion }
            "$host/${LeapPaths.CAROWNER}/v3/api/appremotectl/appointment"
        } else {
            "${route.appRegion}/app/${LeapPaths.APP_CONTROL}/v3/api/appremotectl"
        }

        // 每次重试都重新构造：oppwd 用的是**当下**那份老 token，续期后必须换成新的，
        // 否则刷新完再重试仍然是同一个解不开的密文。
        fun buildBody(): Map<String, String> {
            val params = mutableMapOf(
                "cmdid" to command.cmdid,
                "state" to command.stateJSON,
                "carvin" to current.selectedVin,
            )
            if (operationPassword.isNotEmpty()) {
                params["oppwd"] = LeapCrypto.encryptOperationPassword(
                    operationPassword,
                    current.oldAuth?.token ?: oldAuth.token,
                )
            }
            return oldSignedParams(params)
        }

        val response = oldAuthedRequest("${command.label}指令下发失败，请稍后重试") {
            request(url = url, method = "POST", headers = oldAppHeaders(), formBody = buildBody())
        }
        // 车没动作时，第一件要分清的事是「指令根本没发出去」还是「发出去了车不认」。
        // 没有这条日志，两种情况在外面看长得一模一样。
        DiagLog.note(
            "[control] cmdid=${command.cmdid} state=${command.stateJSON}" +
                " code=${response.responseCode ?: "nil"}" +
                " msg=${response.responseMessage.ifEmpty { "(空)" }}",
        )
        assertSuccess(response, "${command.label}指令发送失败")

        val msgID = response.firstObject { it["msgID"] != null || it["msgId"] != null }
            ?.let { (it["msgID"] ?: it["msgId"])?.stringValue }
            ?: response.get("data")?.stringValue
            ?: ""
        return ControlReceipt(msgID = msgID, label = command.label, sentAt = System.currentTimeMillis())
    }

    /// 回读车上已有的预约（目前只用于 cmdid 171 预约空调）。同 iOS `fetchAppointmentControls`。
    ///
    /// `GET {appCenter}/carownerservice/v3/api/appremotectl/getappointment?carvin=&cmdid=`，
    /// 老签名，host 取 `appCenter ?: appRegion`（和下发预约的端点同一台）。出处是 leapauto 记录的
    /// 官方抓包 `[334]`。`data` 本身是一段 JSON 字符串，解析见
    /// `ClimateAppointment.controlsFromAppointmentData`。解析不出抛错——那是「读不到」，
    /// 和「车上没有预约」（空列表）是两回事，界面要分开说。
    suspend fun fetchAppointmentControls(cmdid: String): List<JsonValue> {
        if (current.selectedVin.isEmpty()) throw LeapError.missingVehicle()
        if (current.oldAuth == null) throw LeapError.notLoggedIn()
        ensureFreshOldToken()
        val route = ensureRoute()
        val host = route.appCenter.ifEmpty { route.appRegion }
        val response = oldAuthedRequest("读取预约失败") {
            request(
                url = "$host/${LeapPaths.CAROWNER}/v3/api/appremotectl/getappointment",
                method = "GET",
                headers = oldAppHeaders(),
                query = oldSignedParams(mapOf("carvin" to current.selectedVin, "cmdid" to cmdid)),
            )
        }
        assertSuccess(response, "读取预约失败")
        return ClimateAppointment.controlsFromAppointmentData(response.get("data"))
            ?: throw LeapError.server("预约数据格式无法识别")
    }

    /// 查询指令执行结果。服务端是异步执行，下发成功不等于车辆已响应。
    suspend fun queryControlResult(msgID: String): JsonValue {
        if (msgID.isEmpty()) throw LeapError.server("msgID 为空")
        val route = ensureRoute()
        ensureFreshOldToken()
        val url = "${route.appRegion}/app/${LeapPaths.APP_CONTROL}/v3/api/appremotectl/query"
        return oldAuthedRequest("指令结果查询失败，请稍后重试") {
            request(
                url = url,
                method = "GET",
                headers = oldAppHeaders(),
                query = oldSignedParams(mapOf("msgID" to msgID)),
            )
        }
    }

    // MARK: - 车模

    /// 拉爱车页车模型。`carpicture/3d/key` 一个接口就区分 2D/3D（见 `CarModel`）。
    /// 走老签名 + host 回退（carpicture 挂在 appCenter，优先它）。
    suspend fun fetchCarModel(): CarModel {
        val route = ensureRoute()
        ensureFreshOldToken()
        val hosts = listOf(route.appCenter, route.appRegion, LeapConstants.GLOBAL_HOST)
            .filter { it.isNotEmpty() }.distinct()
        val vin = current.selectedVin
        for (host in hosts) {
            try {
                val response = request(
                    url = "$host/${LeapPaths.CAROWNER}/v3/api/carpicture/3d/key",
                    method = "GET",
                    headers = oldAppHeaders(),
                    query = oldSignedParams(mapOf("vin" to vin)),
                )
                val model = CarModel.fromRaw(response)
                DiagLog.note(
                    "[carmodel] host=$host success=${response.isSuccess}" +
                        " code=${response.responseCode ?: "nil"} parsed=${model != null}"
                )
                if (response.isSuccess && model != null) return model
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                DiagLog.note("[carmodel] host=$host 抛错：${LeapError.messageOf(e)}")
            }
        }
        throw LeapError.server("车模型接口无数据")
    }

    /// 下载车模资源包（3D 的模型 zip / 渲染器 zip，或 2D 的分层贴图 zip）。
    ///
    /// 走的是 `carpicture/key/package`，返回体是 ZIP 二进制而不是 JSON，
    /// 所以不能借 `request`——它会把响应当 JSON 解，几 MB 的包再塞进字符串。
    suspend fun fetchCarModelPackage(key: String): ByteArray {
        if (key.isEmpty()) throw LeapError.server("资源 key 为空")
        val route = ensureRoute()
        ensureFreshOldToken()
        val hosts = listOf(route.appCenter, route.appRegion).filter { it.isNotEmpty() }.distinct()
        for (host in hosts) {
            val query = oldSignedParams(mapOf("key" to key))
                .entries.joinToString("&") { (k, v) -> "$k=" + URLEncoder.encode(v, "UTF-8") }
            val url = "$host/${LeapPaths.CAROWNER}/v3/api/carpicture/key/package?$query"
            val data = HttpTransport.download(url, oldAppHeaders()) ?: continue
            // 鉴权失败时服务端回的是 JSON 错误体，用 ZIP 魔数把它和真包区分开。
            if (data.size >= 2 && data[0] == 0x50.toByte() && data[1] == 0x4B.toByte()) return data
            DiagLog.note("[carmodel] host=$host 返回的不是 ZIP（${data.size} 字节），换下一个 host")
        }
        throw LeapError.server("车模型资源包下载失败")
    }

    // TODO(P8)：蓝牙钥匙证书同步（`fetchBLEKeyCertificate`，走
    //   `carownerservice/v3/api/bluetoothkey/combine/syncBluetoothKeys`）留到蓝牙那期，
    //   它依赖 `LeapBLEKeyCertificate` 与两个证书存储。

    // MARK: - 请求装配

    /// 老链路通用头。
    ///
    /// `includeToken = false` 用于登录、发验证码这类**建立身份之前**的请求：它们不该带
    /// `XFX-CDN-CROSS-NODE`。本机手里那份 token 在被挤下线后已经作废，带上去只会让服务端
    /// 拒掉整个请求。靠调用点当时 `oldAuth` 恰好为空来保证是不够的——显式关掉。
    private fun oldAppHeaders(includeToken: Boolean = true): Map<String, String> {
        val session = current
        val headers = mutableMapOf(
            "APPPlatform" to "Android",
            "APPVersion" to session.appVersion,
            "APPImei" to session.deviceId,
            "C-VERSIONS" to "APP",
            LeapHeaders.XFX_VRS to "v4",
        )
        val token = session.oldAuth?.token
        if (includeToken && !token.isNullOrEmpty()) {
            headers[LeapHeaders.XFX_CROSS_NODE] = token
        }
        return headers
    }

    /// 老链路签名：timespan/nonce/deviceID/token + 业务参数，排序拼接后取短 MD5；token 本身不发送。
    private fun oldSignedParams(params: Map<String, String>): Map<String, String> {
        // 设备号是服务端认这条会话的凭据，签名里少了它必然 result=39。
        // 宁可这一次请求失败，也别拿一个空设备号去撞——撞出来的 39 会被上层当成「token 过期」。
        requireDeviceId()
        val session = current
        val oldAuth = session.oldAuth ?: throw LeapError.notLoggedIn()
        val map = linkedMapOf(
            "timespan" to System.currentTimeMillis().toString(),
            "nonce" to LeapCrypto.randomNonce(),
            "deviceID" to session.deviceId,
            "token" to oldAuth.token,
        )
        map.putAll(params)
        val signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map))
        map.remove("token")
        map["signStr"] = signStr
        return map
    }

    /// 新网关签名：固定 8 个头字段 + 业务参数一起参与签名。
    /// 登录前用 sha256，登录后用 HMAC-SHA256(signKey)。
    private fun newGatewayHeaders(params: Map<String, String>, needLogin: Boolean): Map<String, String> {
        requireDeviceId()
        val session = current
        val nonce = LeapCrypto.randomNonce()
        val timestamp = System.currentTimeMillis().toString()
        val headers = mutableMapOf(
            "source" to LeapHeaders.VAL_LEAPMOTOR,
            "channel" to "1",
            "acceptLanguage" to "zh-CN",
            LeapHeaders.REGION to "CN",
            LeapHeaders.API_SIG_VERSION to "2.0",
            "digest" to "",
            "version" to session.appVersion,
            "deviceType" to "android",
            "nonce" to nonce,
            "timestamp" to timestamp,
            "deviceId" to session.deviceId,
            "userId" to (session.newAuth?.accountId ?: session.oldAuth?.accountId ?: ""),
            "carvin" to session.selectedVin,
            "cartype" to session.selectedCarType,
            LeapHeaders.SUB_VERSION to session.subVersion,
        )
        val signHeaders = mapOf(
            "acceptLanguage" to "zh-CN",
            "channel" to "1",
            "deviceId" to session.deviceId,
            "deviceType" to "android",
            "nonce" to nonce,
            "source" to LeapHeaders.VAL_LEAPMOTOR,
            "timestamp" to timestamp,
            "version" to session.appVersion,
        )
        val signBase = LeapCrypto.sortAndConcatValues(signHeaders, params)
        if (needLogin) {
            val newAuth = session.newAuth
            if (newAuth == null || newAuth.accessToken.isEmpty() || newAuth.signKeyData.isEmpty()) {
                throw LeapError.notLoggedIn()
            }
            headers["token"] = newAuth.accessToken
            if (newAuth.accountId.isNotEmpty()) headers["userId"] = newAuth.accountId
            headers["sign"] = LeapCrypto.hmacSHA256Hex(signBase, newAuth.signKeyData)
        } else {
            headers["sign"] = LeapCrypto.sha256Hex(signBase)
        }
        return headers
    }

    /// 新网关请求：先按需续期，失败时再续期重试一次。
    private suspend fun newGatewayRequest(
        url: String,
        method: String,
        params: Map<String, String>,
        query: Map<String, String>? = null,
        jsonBody: Map<String, String>? = null,
    ): JsonValue {
        awaitOngoingRefresh()
        ensureFreshAccessToken()

        suspend fun perform(): JsonValue = request(
            url = url,
            method = method,
            headers = newGatewayHeaders(params, needLogin = true),
            query = query,
            jsonBody = jsonBody,
        )

        try {
            val response = perform()
            if (!isNewAuthFailure(response)) return response
        } catch (e: LeapError) {
            val recoverable = e.kind == LeapErrorKind.Http && (e.httpStatus == 401 || e.httpStatus == 403)
            if (!recoverable) throw e
        }
        refreshAccessToken()
        val retried = perform()
        // 续期之后还是被拒，说明登录态真的失效了。这里不抛出去的话，界面会一直停在首页
        // 反复弹同一条错误，永远回不到登录页。
        if (isNewAuthFailure(retried)) throw LeapError.sessionExpired()
        return retried
    }

    // MARK: - 传输

    /// 所有 HTTP 请求的统一出口：带一次瞬时错误重试，并把底层异常翻成用户话。
    ///
    /// **锁屏久了再解锁，回前台第一发几乎必失败**，成因不在我们这边：系统在息屏期间会挂起
    /// 网络接口（Wi-Fi 省电断链、蜂窝无线电休眠、运营商 NAT 表项超时），而连接池里那几条
    /// keep-alive 的 TLS 连接其实已经死了、池子却不知道。解锁后复用死连接发第一个包，
    /// 内核立刻回 RST。唯一可靠的办法是重发一次——第一次失败时坏连接已被踢出连接池。
    ///
    /// 重试范围只收**连接层就失败**的错误，也就是包根本没能交给服务端的那几种；控车这类
    /// 非幂等 POST 走的也是这里，重发不会变成重复下发。超时不在其列——请求可能已经到了
    /// 服务端、只是回包慢，所以只有幂等的 GET 才让它重试。证书类错误一概不重试：重发同样
    /// 过不去，而且可能是中间人。
    private suspend fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        query: Map<String, String>? = null,
        jsonBody: Map<String, String>? = null,
        formBody: Map<String, String>? = null,
        emptyBody: Boolean = false,
    ): JsonValue {
        val bodyKind = when {
            jsonBody != null -> BodyKind.Json
            formBody != null -> BodyKind.Form
            emptyBody -> BodyKind.Empty
            else -> BodyKind.None
        }
        val body = jsonBody ?: formBody
        val retriesOnTimeout = method.uppercase() == "GET"
        return try {
            HttpTransport.request(url, method, headers, query, bodyKind, body)
        } catch (e: Throwable) {
            if (!isRetriableTransportFailure(e, retriesOnTimeout)) throw LeapError.wrapping(e)
            DiagLog.note("[net] ${url.substringBefore('?')} 瞬时网络错误（${e::class.simpleName}），重发一次")
            // 给刚唤醒的网络接口一点时间，也确保坏连接确实已从连接池里摘掉。
            delay(300)
            try {
                HttpTransport.request(url, method, headers, query, bodyKind, body)
            } catch (retryError: Throwable) {
                DiagLog.note("[net] 重发仍失败（${retryError::class.simpleName}）")
                throw LeapError.wrapping(retryError)
            }
        }
    }

    private fun assertSuccess(response: JsonValue, fallback: String) {
        if (response.isSuccess) return
        val message = response.responseMessage
        throw LeapError.server(message.ifEmpty { fallback })
    }

    private fun String.trimTrailingSlash(): String = trimEnd('/')

    companion object {

        /// 连败到什么程度才算「重试也不会好」。抽成纯函数是为了能测。
        fun shouldEscalateOldAuthFailure(streak: Int, spannedSeconds: Long): Boolean =
            streak >= LeapConstants.OLD_AUTH_FAILURE_ESCALATION_COUNT &&
                spannedSeconds >= LeapConstants.OLD_AUTH_FAILURE_ESCALATION_WINDOW

        /// 把 `source` 的凭证盖到 `base` 上，选中车、车辆列表、路由一概保留 `base` 的。
        ///
        /// 返回 null 表示**这一次不该写**：`base` 里已经没有凭证了，说明续期这段时间里
        /// 用户退了登（`logout` 会写一份空会话）。这时候把手里的新凭证写回去，
        /// 等于把刚退出的用户又装回登录态。
        ///
        /// 抽成静态纯函数是为了能测——`persistTokens` 本身要碰加密存储。
        fun merging(source: LeapSession, base: LeapSession): LeapSession? {
            if (base.oldAuth == null && base.newAuth == null) return null
            return base.copy(
                oldAuth = source.oldAuth,
                newAuth = source.newAuth,
                authRevision = source.authRevision,
                phone = if (source.phone.isNotEmpty()) source.phone else base.phone,
            )
        }

        /// 这张判据表要被测试逐条钉住，所以是 internal 而非 private。
        fun isRetriableTransportFailure(error: Throwable, retriesOnTimeout: Boolean): Boolean = when (error) {
            // 协程取消不是网络故障，重发只会把已取消的工作又跑一遍。
            is CancellationException -> false
            // 已经是业务 / HTTP 错误，包早就到服务端了，重发是同一个结果。
            is LeapError -> false
            // 证书对不上：重发同样过不去，而且可能是中间人。
            is SSLHandshakeException, is SSLPeerUnverifiedException -> false
            // 请求可能已经到服务端了，只有幂等的才敢重发。
            // InterruptedIOException 是 SocketTimeoutException 的父类，也是 OkHttp
            // callTimeout 超时时抛的那一个。
            is SocketTimeoutException, is InterruptedIOException -> retriesOnTimeout
            // 连接层就断了，包没能交给服务端——非幂等请求重发也安全。
            is UnknownHostException, is ConnectException, is NoRouteToHostException,
            is SocketException, is SSLException,
            -> true
            // 复用死连接的典型形态：OkHttp 读响应头时发现对端已经关了。
            is IOException -> error.message?.contains("unexpected end of stream", ignoreCase = true) == true
            else -> false
        }

        // MARK: - 响应解析

        private fun extractOldAuth(response: JsonValue): OldAuth {
            val node = response.path("data", "appLoginVO")?.objectValue
                ?: response.path("data", "appOneLoginVO")?.objectValue
                ?: response.firstObject { it["accountId"] != null && it["token"] != null }
            val accountId = node?.get("accountId")?.stringValue
            val token = node?.get("token")?.stringValue
            if (node == null || accountId == null || token == null) {
                throw LeapError.decode("登录响应里没有 accountId/token")
            }
            val expiredSeconds = node["tokenExpired"]?.stringValue?.toDoubleOrNull() ?: 0.0
            val now = System.currentTimeMillis()
            return OldAuth(
                accountId = accountId,
                token = token,
                refreshToken = node["refreshToken"]?.stringValue.orEmpty(),
                nickname = node["nickname"]?.stringValue.orEmpty(),
                tokenExpired = if (expiredSeconds > 0) expiredSeconds.toLong().toString() else "",
                tokenObtainedAt = now,
                tokenExpiresAt = if (expiredSeconds > 0) now + (expiredSeconds * 1000).toLong() else 0,
            )
        }

        private fun extractNewAuth(response: JsonValue, oldAuth: OldAuth?): NewAuth {
            val node = response.get("data")?.objectValue
                ?: response.firstObject { it["accessToken"] != null && it["signParam"] != null }
            val accessToken = node?.get("accessToken")?.stringValue
            val r2 = node?.get("signParam")?.get("r2")?.stringValue
            val r3 = node?.get("signParam")?.get("r3")?.stringValue
            if (node == null || accessToken == null || r2 == null || r3 == null) {
                throw LeapError.decode("新网关响应里没有 accessToken/signParam")
            }
            val signKey = LeapCrypto.deriveSignKey(accessToken, r2, r3)
            val jwtExpiry = LeapCrypto.jwtExpiryMilliseconds(accessToken)
            val fallbackExpiry = node["tokenExpireTime"]?.stringValue?.toDoubleOrNull()
                ?.let { System.currentTimeMillis() + (it * 1000).toLong() } ?: 0
            return NewAuth(
                accountId = oldAuth?.accountId ?: node["accountId"]?.stringValue.orEmpty(),
                gatewayAccountId = node["accountId"]?.stringValue.orEmpty(),
                accessToken = accessToken,
                refreshToken = node["refreshToken"]?.stringValue.orEmpty(),
                accessTokenExpiresAt = if (jwtExpiry > 0) jwtExpiry else fallbackExpiry,
                nickname = node["nickname"]?.stringValue.orEmpty(),
                signKeyBase64 = LeapCrypto.base64Encode(signKey),
            )
        }

        /// 需要重新登录的强判据文案：命中任意一条即视为登录态失效。
        /// 两类：登录/会话/token 明确过期失效、异地或他设备登录被挤下线。
        /// 匹配前统一小写并去空格，容忍「token 失效」这种中间带空格的写法。
        ///
        /// 这张表只收「除了重新登录没有别的解释」的文案。以下几条曾经在表里，都撤了：
        /// - 「已下线」：撞的是「**车辆**已下线」，车在休眠而已，跟登录态无关。
        /// - 「未授权」：撞的是「未授权访问该车辆」，是这辆车的权限问题。
        /// - 「信息校验失败」：老链路签名不过就是这句——设备时钟偏一点、nonce 撞了都会出，
        ///   续期救不了它，重试还是同一句，于是稳定地把用户踢回登录页。
        /// - 「鉴权失败」「认证失败」「身份验证失败」：同一个理由，签名不过也叫这几个名字。
        /// 宁可漏判：漏了顶多多弹一次错误提示，误判是直接清掉登录态。
        private val reauthPhrases = listOf(
            // 登录 / 会话 过期失效
            "重新登录", "登录已失效", "登录失效", "登录已过期", "登录过期",
            "登录信息已过期", "登录信息失效", "登录状态已失效", "登录状态失效", "登录态失效",
            "会话已过期", "会话过期", "会话失效", "账号已失效", "账号失效",
            // token 类
            "token失效", "token已失效", "token过期", "token已过期",
            "tokeninvalid", "tokenexpired", "第三方token失效",
            // 异地 / 他设备登录被挤下线
            "异地登录", "其他设备登录", "其它设备登录", "别处登录", "别的设备登录",
            "换设备登录", "其他终端登录", "被挤下线", "顶下线", "强制下线",
            // 未登录：服务端明说这次请求没带上有效身份，没有第二种解释。
            "未登录",
        )

        private fun matchesReauthPhrase(message: String): Boolean {
            val normalized = message.lowercase().replace(" ", "")
            return reauthPhrases.any { normalized.contains(it) }
        }

        /// 老链路失效标志：result=39 或命中失效文案。
        fun isOldAuthFailure(response: JsonValue): Boolean {
            if (response.get("result")?.stringValue == "39") {
                AuthAuditLog.note("老链路 result=39，判定登录态失效")
                return true
            }
            val message = response.responseMessage
            if (matchesReauthPhrase(message)) {
                AuthAuditLog.note("老链路命中失效文案：$message")
                return true
            }
            return false
        }

        fun isNewAuthFailure(response: JsonValue): Boolean {
            val code = response.responseCode
            if (code == "401" || code == "403") {
                AuthAuditLog.note("新链路 code=$code，判定登录态失效")
                return true
            }
            val message = response.responseMessage
            if (matchesReauthPhrase(message)) {
                AuthAuditLog.note("新链路命中失效文案：$message")
                return true
            }
            // 这里原来还有一条组合兜底：消息里同时出现「登录/鉴权/认证/授权/token」和
            // 「过期/失效/无效」就判失效。撤掉了——「无效」「授权」在业务报错里太常见，
            // 「该车辆未授权，参数无效」这种句子会被它一并判成登录失效，把人踢回登录页。
            // 401/403 才是新链路的强判据，兜底那点覆盖率不值这个代价。
            // 成功响应也会走这个判断，别把正常返回也刷进日志。
            if (!response.isSuccess && message.isNotEmpty()) {
                DiagLog.note("[auth] 新链路未命中失效判据，按业务错误处理：$message")
            }
            return false
        }
    }
}
