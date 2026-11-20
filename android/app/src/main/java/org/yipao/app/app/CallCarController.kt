package org.yipao.app.app

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.compose.runtime.*
import org.yipao.app.core.*
import kotlinx.coroutines.*
import java.util.UUID

/** EEED 座舱专用连接，所有状态与 GATT 回调串行回到 Main。 */
@SuppressLint("MissingPermission")
class CallCarController {
    var straightMoveState by mutableStateOf<BLEStraightMoveState>(BLEStraightMoveState.Idle)
        private set
    var authenticated by mutableStateOf(false)
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var context: BLECredentialContext? = null
    private var gatt: BluetoothGatt? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private var scanner: BluetoothLeScanner? = null
    private var crypto: LeapBLECryptoSession? = null
    private var buffer = CallCarPacketBuffer()
    private var order = 3
    private var chunks = ArrayDeque<ByteArray>()
    private var writing = false
    private var lastWrite = 0L
    private var lastResponse = 0L
    private var generation = 0
    private var closing = false
    private var active = true
    private var timer: Job? = null

    private fun trace(message: String, category: String = "COCKPIT") {
        if (BLETrace.note(category, message)) DiagLog.note("[ble:$category] $message")
    }

    private fun setState(value: BLEStraightMoveState) {
        if (straightMoveState != value) trace("state=${value.logLabel()}")
        straightMoveState = value
    }

    fun configure(value: BLECredentialContext?) {
        if (context?.vin != value?.vin || context?.accountId != value?.accountId ||
            context?.certificate?.fingerprint != value?.certificate?.fingerprint) closeStraightMove()
        context = value
    }
    fun setApplicationActive(value: Boolean) { active = value; if (!active) closeStraightMove() }
    suspend fun prepareStraightMove() {
        trace("prepare certificate=${context != null} active=$active")
        check(active && context != null) { "请同步车辆蓝牙证书并保持 App 在前台" }
        disconnect(); generation++
        val epoch = generation
        closing = false
        setState(BLEStraightMoveState.Preparing)
        try {
            val adapter = AppEnv.context.getSystemService(BluetoothManager::class.java)?.adapter
            check(adapter?.isEnabled == true) { "请打开手机蓝牙" }
            scanner = adapter.bluetoothLeScanner
            trace("scan.start service=EEED")
            scanner?.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(CallCarProtocol.SERVICE))).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
            val deadline = SystemClock.elapsedRealtime() + 50_000
            while (SystemClock.elapsedRealtime() < deadline) {
                check(epoch == generation) { "直进直出连接已取消" }
                if (straightMoveState == BLEStraightMoveState.Ready) return
                (straightMoveState as? BLEStraightMoveState.Failed)?.let { error(it.message) }
                delay(80)
            }
            error("车辆直进直出未就绪，请检查上电、车门、P 档和周围环境")
        } catch (e: Exception) {
            if (epoch == generation) fail(e.message ?: "座舱连接失败")
            throw e
        }
    }
    fun startStraightMove(direction: StraightMoveDirection) {
        check(active && !closing && authenticated && straightMoveState == BLEStraightMoveState.Ready &&
            SystemClock.elapsedRealtime() - lastResponse < 1000) { "请等待车辆就绪；暂停后需先恢复" }
        order = if (direction == StraightMoveDirection.Forward) 1 else 2
        setState(BLEStraightMoveState.Moving(direction))
        sendOrder()
    }
    fun stopStraightMove() {
        if (!authenticated || closing) return
        order = 3; setState(BLEStraightMoveState.Paused); sendOrder()
    }
    fun resume() {
        if (!authenticated || closing || straightMoveState != BLEStraightMoveState.Paused) return
        order = 4; setState(BLEStraightMoveState.Preparing); sendOrder()
    }
    fun closeStraightMove() {
        trace("close authenticated=$authenticated")
        generation++; val epoch = generation
        closing = true; order = 3; setState(BLEStraightMoveState.Idle)
        if (authenticated) {
            sendOrder()
            scope.launch {
                delay(200); if (epoch != generation) return@launch
                order = 6; sendOrder(); delay(200)
                if (epoch == generation) disconnect()
            }
        } else disconnect()
    }
    private fun fail(message: String) {
        trace("fail message=$message")
        BLETrace.replay("直进直出失败：$message")
        closeStraightMove()
        setState(BLEStraightMoveState.Failed(message))
    }
    private fun disconnect() {
        trace("disconnect local=true")
        timer?.cancel(); timer = null
        runCatching { scanner?.stopScan(scanCallback) }; scanner = null
        val old = gatt; gatt = null
        runCatching { old?.disconnect(); old?.close() }
        characteristic = null; crypto = null; authenticated = false
        buffer = CallCarPacketBuffer(); chunks.clear(); writing = false
    }
    private val scanCallback: ScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            scope.launch {
                if (gatt != null || closing) return@launch
                val vin = context?.vin ?: return@launch
                val items = result.scanRecord?.manufacturerSpecificData ?: return@launch
                val matches = (0 until items.size()).any { i ->
                    val company = items.keyAt(i)
                    CallCarProtocol.matches(byteArrayOf(company.toByte(), (company shr 8).toByte()) + items.valueAt(i), vin)
                }
                if (!matches) return@launch
                trace("scan.match rssi=${result.rssi}")
                scanner?.stopScan(scanCallback)
                trace("connect.request")
                gatt = result.device.connectGatt(AppEnv.context, false, callback, BluetoothDevice.TRANSPORT_LE)
            }
        }
        override fun onScanFailed(errorCode: Int) { scope.launch {
            trace("scan.failed code=$errorCode")
            fail("座舱蓝牙扫描失败（$errorCode）")
        } }
    }
    private val callback: BluetoothGattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(link: BluetoothGatt, status: Int, newState: Int) { scope.launch {
            if (link !== gatt) return@launch
            trace("connection status=$status state=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                authenticated = false; fail("座舱蓝牙已断开"); return@launch
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                trace("services.discover start=true")
                if (!link.discoverServices()) fail("座舱服务发现失败")
            }
        } }
        override fun onServicesDiscovered(link: BluetoothGatt, status: Int) { scope.launch {
            if (link !== gatt) return@launch
            val target = link.getService(UUID.fromString(CallCarProtocol.SERVICE))?.getCharacteristic(UUID.fromString(CallCarProtocol.CHARACTERISTIC))
            val descriptor = target?.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
            trace("services.discovered status=$status count=${link.services.size} target=${target != null} cccd=${descriptor != null}")
            if (status != 0 || target == null || descriptor == null || target.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0) {
                fail("车辆未提供直进直出服务"); return@launch
            }
            characteristic = target
            if (!link.setCharacteristicNotification(target, true)) { fail("座舱蓝牙订阅失败"); return@launch }
            trace("notify.request")
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (!link.writeDescriptor(descriptor)) fail("座舱蓝牙订阅失败")
        } }
        override fun onDescriptorWrite(link: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) { scope.launch {
            if (link !== gatt) return@launch
            trace("notify.ack status=$status")
            if (status != 0) { fail("座舱蓝牙订阅失败"); return@launch }
            try {
                val c = context ?: error("证书已失效")
                val session = LeapBLECryptoSession.make(c.certificate, c.vin)
                crypto = session
                val frame = session.callCarAuthenticationFrame(c.certificate, c.accountId, c.deviceId)
                trace("auth.frame bytes=${frame.size}")
                write(frame)
            } catch (e: Exception) { fail(e.message ?: "座舱认证失败") }
        } }
        override fun onCharacteristicWrite(link: BluetoothGatt, target: BluetoothGattCharacteristic, status: Int) { scope.launch {
            if (link !== gatt) return@launch
            trace("tx.ack status=$status remaining=${chunks.size}", "COCKPIT-TX")
            if (status != 0) { authenticated = false; fail("座舱写入失败") } else nextChunk()
        } }
        override fun onCharacteristicChanged(link: BluetoothGatt, target: BluetoothGattCharacteristic, value: ByteArray) {
            val data = value.copyOf(); scope.launch { receive(link, data) }
        }
        @Deprecated("Legacy callback")
        override fun onCharacteristicChanged(link: BluetoothGatt, target: BluetoothGattCharacteristic) {
            if (android.os.Build.VERSION.SDK_INT < 33) { val data = target.value.copyOf(); scope.launch { receive(link, data) } }
        }
    }
    private fun write(bytes: ByteArray) {
        trace("tx.request header=${LeapCrypto.toHex(bytes.copyOfRange(0, minOf(2, bytes.size))).uppercase()} bytes=${bytes.size} busy=$writing order=$order", "COCKPIT-TX")
        if (writing || gatt == null || characteristic == null) return
        chunks = ArrayDeque(bytes.toList().chunked(20).map { it.toByteArray() })
        writing = true; lastWrite = SystemClock.elapsedRealtime(); nextChunk()
    }
    private fun nextChunk() {
        if (chunks.isEmpty()) { writing = false; return }
        val target = characteristic ?: return
        target.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        target.value = chunks.removeFirst()
        if (gatt?.writeCharacteristic(target) != true) { authenticated = false; fail("座舱写入失败") }
    }
    private fun sendOrder() {
        if (!authenticated || writing) return
        try { crypto?.callCarOrderFrame(order)?.let(::write) } catch (e: Exception) { authenticated = false; fail("座舱加密失败") }
    }
    private fun receive(link: BluetoothGatt, data: ByteArray) {
        if (link !== gatt || closing) return
        trace("rx.chunk bytes=${data.size}", "COCKPIT-RX")
        try {
            for (packet in buffer.append(data)) {
                if (closing) return
                trace("rx.frame type=${packet.type} bytes=${packet.payload.size}", "COCKPIT-RX")
                check(packet.type != 0) { "座舱认证失败，请重新同步蓝牙证书" }
                val size = packet.payload.size
                val raw = byteArrayOf(0xAA.toByte(), 0xAB.toByte()) + (0..3).map { (size shr (it * 8)).toByte() }.toByteArray() + packet.payload
                val plain = crypto?.decrypt(LeapBLEFrame(LeapBLEFrameKind.Encrypted, size, raw)) ?: error("座舱会话已失效")
                val status = CallCarStatus.parse(LeapCrypto.utf8(plain)) ?: error("无法识别座舱状态")
                authenticated = true; lastResponse = SystemClock.elapsedRealtime()
                trace("rx.status kind=${status.kind.name} reason=${status.reason}", "COCKPIT-RX")
                when (status.kind) {
                    CallCarStatus.Kind.Waiting -> if (straightMoveState == BLEStraightMoveState.Ready || straightMoveState.isMoving) {
                        order = 3; setState(BLEStraightMoveState.Preparing)
                    }
                    CallCarStatus.Kind.Activate -> { order = 5; setState(BLEStraightMoveState.Preparing) }
                    CallCarStatus.Kind.Ready -> if (!straightMoveState.isMoving) { order = 3; setState(BLEStraightMoveState.Ready) }
                    CallCarStatus.Kind.Paused -> { order = 3; setState(BLEStraightMoveState.Paused) }
                    CallCarStatus.Kind.Failed -> fail("车辆退出直进直出（原因 ${status.reason}）")
                    CallCarStatus.Kind.Unavailable -> fail("车辆暂不可用，请检查车门、P 档和踏板（原因 ${status.reason}）")
                }
                if (!closing && timer == null) timer = scope.launch {
                    trace("heartbeat.start intervalMs=100")
                    while (isActive) {
                        delay(100)
                        val now = SystemClock.elapsedRealtime()
                        if (!closing && (now - lastResponse > 1000 || (writing && now - lastWrite > 350))) {
                            fail("座舱控制连接超时，已停止"); return@launch
                        }
                        sendOrder()
                    }
                }
            }
        } catch (e: Exception) { fail(e.message ?: "座舱回包异常") }
    }

    private fun BLEStraightMoveState.logLabel(): String = when (this) {
        BLEStraightMoveState.Idle -> "idle"
        BLEStraightMoveState.Preparing -> "preparing"
        BLEStraightMoveState.Ready -> "ready"
        BLEStraightMoveState.Paused -> "paused"
        is BLEStraightMoveState.Moving -> "moving:${direction.name}"
        is BLEStraightMoveState.Failed -> "failed:$message"
    }
}
