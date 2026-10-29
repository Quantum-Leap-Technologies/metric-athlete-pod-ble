package com.example.pod_connector

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PacketFramingTest {
    private fun le(n: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(n).array()

    /** A header packet as the pod sends it: 0xAE, type, 3 bytes, count LE, payload. */
    private fun headerPacket(type: Int, count: Int, payload: ByteArray = ByteArray(0)) =
        byteArrayOf(0xAE.toByte(), type.toByte(), 0, 0, 0) + le(count) + payload

    @Test fun stripsTheFrameByte() {
        val packet = byteArrayOf(0xAE.toByte(), 0x03, 1, 2, 3)
        assertArrayEquals(byteArrayOf(0x03, 1, 2, 3), PacketFraming.stripFrameByte(packet))
    }

    @Test fun leavesPacketsWithoutTheFrameByteAlone() {
        val packet = byteArrayOf(0x03, 1, 2, 3)
        assertArrayEquals(packet, PacketFraming.stripFrameByte(packet))
    }

    @Test fun aLoneFrameByteIsNotStripped() {
        val packet = byteArrayOf(0xAE.toByte())
        assertArrayEquals(packet, PacketFraming.stripFrameByte(packet))
    }

    @Test fun readsTheRealPacketCountFromTheHeader() {
        val header = PacketFraming.stripFrameByte(headerPacket(type = 0x03, count = 10033))
        assertEquals(0x03, PacketFraming.messageType(header))
        assertEquals(10033, PacketFraming.expectedPacketCount(header))
        assertTrue(PacketFraming.isReasonablePacketCount(10033))
    }

    @Test fun theCountOffsetIsTheSameRawOrStripped() {
        // The old Android code read the count at raw byte 5; after stripping it is
        // byte 4. For a REAL header packet both give the same, correct count, so the
        // frame byte is not what produced the garbage counts seen in the field (those
        // come from DATA packets being treated as headers). What the old code did get
        // wrong is the message type: it read raw[0], i.e. 0xAE, instead of the type.
        val raw = headerPacket(type = 0x03, count = 10033)
        val rawCount = ByteBuffer.wrap(raw, 5, 4).order(ByteOrder.LITTLE_ENDIAN).int
        val stripped = PacketFraming.stripFrameByte(raw)
        assertEquals(10033, rawCount)
        assertEquals(rawCount, PacketFraming.expectedPacketCount(stripped))
        assertEquals(0xAE, raw[0].toInt() and 0xFF)            // what the old code called the type
        assertEquals(0x03, PacketFraming.messageType(stripped)) // the real type
    }

    @Test fun rejectsUnreasonableCounts() {
        assertFalse(PacketFraming.isReasonablePacketCount(0))
        assertFalse(PacketFraming.isReasonablePacketCount(-2078134006))
        assertFalse(PacketFraming.isReasonablePacketCount(132775938))
        assertTrue(PacketFraming.isReasonablePacketCount(PacketFraming.MAX_EXPECTED_PACKETS))
        assertFalse(PacketFraming.isReasonablePacketCount(PacketFraming.MAX_EXPECTED_PACKETS + 1))
    }

    @Test fun headerPayloadAndDataPayloadSkipTheirOverhead() {
        val body = byteArrayOf(9, 8, 7)
        val header = PacketFraming.stripFrameByte(headerPacket(0x03, 5, body))
        assertArrayEquals(body, PacketFraming.headerPayload(header))

        // Data packet: 0xAE, [type + 3 bytes], payload. After stripping, 4 bytes of overhead.
        val data = PacketFraming.stripFrameByte(byteArrayOf(0xAE.toByte(), 0x03, 0, 0, 0) + body)
        assertArrayEquals(body, PacketFraming.dataPayload(data))
    }

    @Test fun reassemblesAWholeDownload() {
        val total = 4
        val payloads = List(total) { i -> ByteArray(6) { (i * 10 + it).toByte() } }
        val packets = payloads.mapIndexed { i, p ->
            if (i == 0) headerPacket(0x03, total, p)
            else byteArrayOf(0xAE.toByte(), 0x03, 0, 0, 0) + p
        }
        val out = java.io.ByteArrayOutputStream()
        var count = 0
        var expected = 0
        for (packet in packets) {
            val data = PacketFraming.stripFrameByte(packet)
            if (count == 0) {
                expected = PacketFraming.expectedPacketCount(data)
                out.write(PacketFraming.messageType(data))
                out.write(PacketFraming.headerPayload(data))
            } else {
                out.write(PacketFraming.dataPayload(data))
            }
            count++
        }
        assertEquals(total, expected)
        assertEquals(total, count)
        // 1 type byte + the header packet's 6 payload bytes + 3 data packets x 6 bytes.
        assertEquals(1 + 6 + 3 * 6, out.size())
        // And the bytes are the original payloads, in order.
        val expectedBytes = byteArrayOf(0x03) + payloads.reduce { a, b -> a + b }
        assertArrayEquals(expectedBytes, out.toByteArray())
    }
}
