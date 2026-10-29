package com.example.pod_connector

/**
 * Frame parsing for pod file downloads (BLE ICD V3.6), kept free of Android types
 * so it can be unit tested on the JVM.
 *
 * Every notification from the pod is one frame:
 *
 *     [0xAE][type][length][length bytes of payload]
 *
 * For a file download (type 0x03) the payload is raw sensor records, continuing
 * from the previous frame (records span frames). There is NO packet-count header
 * in the download stream: an earlier version read "bytes 4-7 of the first packet"
 * as a count, but those bytes are record data (e.g. EA 07 = the year 2026), which
 * produced counts like 132775936 and dropped one real data byte per frame. The
 * size of the file comes from the file list instead (exact bytes), so completion
 * is "this many payload bytes have arrived".
 */
internal object PacketFraming {
    const val FRAME_BYTE = 0xAE
    const val TYPE_FILE_DATA = 0x03

    /** 0xAE + type + length. */
    const val FRAME_OVERHEAD = 3

    class Frame(val type: Int, val payload: ByteArray)

    /**
     * Parses one notification. Returns null if it is not a frame (too short, or
     * not starting with 0xAE). A length byte larger than what actually arrived (a
     * truncated notification) yields the bytes that are there.
     */
    fun parseFrame(packet: ByteArray): Frame? {
        if (packet.size < FRAME_OVERHEAD) return null
        if ((packet[0].toInt() and 0xFF) != FRAME_BYTE) return null
        val type = packet[1].toInt() and 0xFF
        val length = packet[2].toInt() and 0xFF
        val available = packet.size - FRAME_OVERHEAD
        val count = if (length < available) length else available
        return Frame(type, packet.copyOfRange(FRAME_OVERHEAD, FRAME_OVERHEAD + count))
    }
}
