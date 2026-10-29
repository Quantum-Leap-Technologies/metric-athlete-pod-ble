package com.example.pod_connector

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Packet framing for pod file downloads (BLE ICD V3.6), kept free of Android
 * types so it can be unit tested on the JVM.
 *
 * Every packet from the pod starts with the 0xAE frame byte. iOS/macOS strip it
 * before parsing (commit db457d0); Android used to read the raw packet, so it took
 * 0xAE as the message type (and never saw type 0x03, so Smart Peek never ran).
 * The packet-count offset is unaffected: raw byte 5 is stripped byte 4.
 *
 * After stripping:
 *   header packet: [type][..3 bytes..][packetCount LE x4][payload...]  (8 bytes overhead)
 *   data packet:   [type][..3 bytes..][payload...]                      (4 bytes overhead)
 */
internal object PacketFraming {
    const val FRAME_BYTE = 0xAE
    const val HEADER_OVERHEAD = 8
    const val DATA_OVERHEAD = 4

    /** A 2-hour session at 10 Hz is about 72,000 packets; this leaves headroom
     *  but still rejects corrupt counts before they allocate gigabytes. */
    const val MAX_EXPECTED_PACKETS = 500_000

    /** Drops the leading 0xAE frame byte. A lone 0xAE (size 1) is left as is. */
    fun stripFrameByte(packet: ByteArray): ByteArray =
        if (packet.size >= 2 && (packet[0].toInt() and 0xFF) == FRAME_BYTE) {
            packet.copyOfRange(1, packet.size)
        } else {
            packet
        }

    /** Message type of a header packet (already stripped). */
    fun messageType(header: ByteArray): Int = header[0].toInt() and 0xFF

    /** Expected total packet count from a header packet (already stripped). */
    fun expectedPacketCount(header: ByteArray): Int =
        ByteBuffer.wrap(header, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int

    fun isReasonablePacketCount(count: Int): Boolean = count in 1..MAX_EXPECTED_PACKETS

    /** Payload carried by the header packet itself (already stripped). */
    fun headerPayload(header: ByteArray): ByteArray =
        if (header.size > HEADER_OVERHEAD) header.copyOfRange(HEADER_OVERHEAD, header.size) else ByteArray(0)

    /** Payload carried by a data packet (already stripped). */
    fun dataPayload(data: ByteArray): ByteArray =
        if (data.size > DATA_OVERHEAD) data.copyOfRange(DATA_OVERHEAD, data.size) else ByteArray(0)
}
