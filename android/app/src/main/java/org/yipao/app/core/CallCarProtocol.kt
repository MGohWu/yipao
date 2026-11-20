package org.yipao.app.core

object CallCarProtocol {
    const val SERVICE = "0000eeed-0000-1000-8000-00805f9b34fb"
    const val CHARACTERISTIC = "0000eee2-0000-1000-8000-00805f9b34fb"
    fun matches(manufacturer: ByteArray, vin: String): Boolean = manufacturer.size >= 14 &&
        manufacturer.copyOfRange(6, 14).contentEquals(LeapCrypto.utf8(LeapCrypto.md5Hex(LeapCrypto.utf8(vin)).substring(8, 16)))
}

data class CallCarPacket(val type: Int, val payload: ByteArray)
class CallCarPacketBuffer {
    private var buffer = byteArrayOf()
    fun append(bytes: ByteArray): List<CallCarPacket> {
        buffer += bytes
        val packets = mutableListOf<CallCarPacket>()
        while (buffer.size >= 2) {
            if (buffer[0] != 0xAA.toByte() || buffer[1] != 0xAC.toByte()) { buffer = buffer.drop(1).toByteArray(); continue }
            if (buffer.size < 9) break
            val length = (0..3).fold(0L) { value, index -> value or ((buffer[5 + index].toLong() and 255) shl (index * 8)) }
            require(length <= 65536) { "座舱回包长度异常" }
            if (buffer.size < length + 11) break
            require(buffer[2] == 1.toByte()) { "座舱业务模块不匹配" }
            packets += CallCarPacket((buffer[3].toInt() and 255) or ((buffer[4].toInt() and 255) shl 8), buffer.copyOfRange(9, 9 + length.toInt()))
            buffer = buffer.copyOfRange(11 + length.toInt(), buffer.size)
        }
        return packets
    }
}

data class CallCarStatus(val kind: Kind, val reason: Int = 0) {
    enum class Kind { Waiting, Activate, Ready, Paused, Failed, Unavailable }
    companion object {
        fun parse(text: String): CallCarStatus? {
            val parts = text.split(';')
            if (parts.size < 5) return null
            val values = parts.take(5).map { it.toIntOrNull() ?: return null }
            if (values.any { it < 0 }) return null
            val status = values[1]
            return when {
                values.all { it == 0 } -> CallCarStatus(Kind.Waiting)
                status == 5 -> if (values[2] == 1) CallCarStatus(Kind.Activate) else CallCarStatus(Kind.Unavailable, values[2])
                values[4] != 0 -> CallCarStatus(Kind.Failed, values[4])
                values[3] != 0 -> CallCarStatus(Kind.Paused, values[3])
                values[2] != 0 -> CallCarStatus(Kind.Unavailable, values[2])
                status == 1 -> CallCarStatus(Kind.Waiting)
                status == 2 || status == 6 -> CallCarStatus(Kind.Ready)
                status == 4 -> CallCarStatus(Kind.Paused)
                else -> CallCarStatus(Kind.Failed, status)
            }
        }
    }
}
