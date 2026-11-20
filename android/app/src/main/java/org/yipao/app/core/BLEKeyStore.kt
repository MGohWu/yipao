package org.yipao.app.core

import org.json.JSONObject

/// 蓝牙钥匙的三件套本地存储：证书、快速重连凭证、可信车辆绑定。
/// 对齐 iOS 的 `BLEKeyCertificateStore` / `BLEReconnectTokenStore` / `BLEVehicleBindingStore`。
///
/// 三样都按「账号|VIN」隔离，并且都走 [SecureVault]（Keystore 包着的 AES-GCM），
/// 不能进普通 SharedPreferences——它们合起来等于一把能开车门的钥匙。
///
/// iOS 那边有个 `BLEInstallationGuard`：重装会清 UserDefaults 但**留下钥匙串**，
/// 所以要防「新安装直接接管旧绑定」。安卓不需要——卸载会连同 Keystore 里的密钥一起删，
/// 重装后密文一律解不开，[SecureVault] 直接按「没存过」返回。

private const val CERTIFICATE_PREFIX = "ble.certificate."
private const val TOKEN_PREFIX = "ble.reconnect."
private const val BINDING_PREFIX = "ble.binding."

private fun slot(prefix: String, accountId: String, vin: String) = "$prefix$accountId|$vin"

/// 每车蓝牙证书。同步一次能用很久，但账号或 VIN 一换就必须重新取。
object BLEKeyCertificateStore {

    fun load(accountId: String, vin: String): LeapBLEKeyCertificate? {
        val outcome = SecureVault.read(slot(CERTIFICATE_PREFIX, accountId, vin))
        val text = (outcome as? SecureVault.Outcome.Found)?.value ?: return null
        return LeapBLEKeyCertificate.fromStorage(text)
    }

    fun save(certificate: LeapBLEKeyCertificate, accountId: String, vin: String): Boolean =
        SecureVault.write(slot(CERTIFICATE_PREFIX, accountId, vin), certificate.toJson())

    fun clear(accountId: String, vin: String) {
        SecureVault.remove(slot(CERTIFICATE_PREFIX, accountId, vin))
    }

    fun clearAll() = SecureVault.removeByPrefix(CERTIFICATE_PREFIX)
}

/// 快速重连凭证（车端在完整认证后回的那串 hex）。丢了不影响功能，只是下次要走完整认证。
object BLEReconnectTokenStore {

    fun load(accountId: String, vin: String): String? =
        (SecureVault.read(slot(TOKEN_PREFIX, accountId, vin)) as? SecureVault.Outcome.Found)?.value

    fun save(token: String, accountId: String, vin: String): Boolean =
        SecureVault.write(slot(TOKEN_PREFIX, accountId, vin), token)

    fun clear(accountId: String, vin: String) {
        SecureVault.remove(slot(TOKEN_PREFIX, accountId, vin))
    }

    fun clearAll() = SecureVault.removeByPrefix(TOKEN_PREFIX)
}

enum class BLEConfigurationSyncState {
    Synced,
    Pending,
    PendingDisable,
    ;

    companion object {
        fun of(name: String?) = entries.firstOrNull { it.name == name } ?: Pending
    }
}

/// 一台已认证车辆和它的无感配置。
///
/// [deviceAddress] 是车端 BLE 模块的 MAC。iOS 存的是 CoreBluetooth 那个不透明 UUID，
/// 安卓直接拿 MAC——好处是重连不用先扫描，`getRemoteDevice(mac)` 就能连。
data class BLEVehicleBinding(
    val accountId: String,
    val vin: String,
    val deviceAddress: String,
    val certificateFingerprint: String,
    val configuration: LeapBLEConfiguration,
    val syncState: BLEConfigurationSyncState,
    val removeAfterDisable: Boolean,
    val lastVerifiedAt: Long?,
) {
    val isBluetoothControlEnabled: Boolean
        get() = configuration.isEnabled && syncState != BLEConfigurationSyncState.PendingDisable

    val isPassiveEntryEnabled: Boolean
        get() = isBluetoothControlEnabled &&
            (configuration.autoUnlockEnabled || configuration.autoLockEnabled)

    val shouldMaintainConnection: Boolean
        get() = isBluetoothControlEnabled || syncState == BLEConfigurationSyncState.PendingDisable

    fun toJson(): String = JSONObject()
        .put("accountId", accountId)
        .put("vin", vin)
        .put("deviceAddress", deviceAddress)
        .put("certificateFingerprint", certificateFingerprint)
        .put("configuration", configuration.toJson())
        .put("syncState", syncState.name)
        .put("removeAfterDisable", removeAfterDisable)
        .put("lastVerifiedAt", lastVerifiedAt ?: 0L)
        .toString()

    companion object {
        fun fromJson(text: String): BLEVehicleBinding? {
            val node = JsonValue.parse(text)?.objectValue ?: return null
            val configuration =
                LeapBLEConfiguration.fromJson(node["configuration"]?.objectValue) ?: return null
            val verifiedAt = node["lastVerifiedAt"]?.doubleValue?.toLong() ?: 0L
            return BLEVehicleBinding(
                accountId = node["accountId"]?.stringValue ?: return null,
                vin = node["vin"]?.stringValue ?: return null,
                deviceAddress = node["deviceAddress"]?.stringValue ?: return null,
                certificateFingerprint = node["certificateFingerprint"]?.stringValue.orEmpty(),
                configuration = configuration,
                syncState = BLEConfigurationSyncState.of(node["syncState"]?.stringValue),
                removeAfterDisable = node["removeAfterDisable"]?.boolValue ?: false,
                lastVerifiedAt = verifiedAt.takeIf { it > 0 },
            )
        }
    }
}

object BLEVehicleBindingStore {

    fun load(accountId: String, vin: String): BLEVehicleBinding? {
        val outcome = SecureVault.read(slot(BINDING_PREFIX, accountId, vin))
        val text = (outcome as? SecureVault.Outcome.Found)?.value ?: return null
        val binding = BLEVehicleBinding.fromJson(text) ?: return null
        BLEPairingHistory.recordPaired(binding.accountId, binding.vin)
        return binding
    }

    fun save(binding: BLEVehicleBinding): Boolean {
        val saved = SecureVault.write(
            slot(BINDING_PREFIX, binding.accountId, binding.vin),
            binding.toJson(),
        )
        if (saved) BLEPairingHistory.recordPaired(binding.accountId, binding.vin)
        return saved
    }

    fun clear(accountId: String, vin: String) {
        SecureVault.remove(slot(BINDING_PREFIX, accountId, vin))
    }

    fun clearAll() = SecureVault.removeByPrefix(BINDING_PREFIX)
}

/// 「这台车在这部手机上配对过」的痕迹，专给「需要重新配对」这条提示做归因。
///
/// 退登会把上面三件套一起清掉（和 iOS 一样是有意的：账号都换了，钥匙不能留）。
/// 没有这条痕迹就分不清「配过但被清了」和「从来没配过」，对后者弹这条提示纯属吓人。
/// 放普通 prefs 而不是加密存储：它只影响一条文案，重装丢了就不提示，无害。
object BLEPairingHistory {
    private const val KEY = "ble.everPaired"

    // core 层不引 app 层的 AppPrefs，自己开一份就行——这里只有一组配对痕迹。
    private val prefs get() = AppEnv.prefs("ble-history")

    fun recordPaired(accountId: String, vin: String) {
        val token = "$accountId|$vin"
        val list = prefs.getStringSet(KEY, emptySet()).orEmpty()
        if (list.contains(token)) return
        prefs.edit().putStringSet(KEY, list + token).apply()
    }

    fun hasPaired(accountId: String, vin: String): Boolean =
        prefs.getStringSet(KEY, emptySet()).orEmpty().contains("$accountId|$vin")
}
