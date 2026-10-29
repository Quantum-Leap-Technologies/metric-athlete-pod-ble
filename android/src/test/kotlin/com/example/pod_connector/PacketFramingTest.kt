package com.example.pod_connector

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PacketFramingTest {
    /** One notification as the pod sends it: 0xAE, type, length, payload. */
    private fun frame(type: Int, payload: ByteArray) =
        byteArrayOf(0xAE.toByte(), type.toByte(), payload.size.toByte()) + payload

    @Test fun parsesARealDownloadFrame() {
        // From the field log: [0xAE][0x03][len=0xF1][241 bytes of records]
        val records = ByteArray(241) { (it % 251).toByte() }
        val f = PacketFraming.parseFrame(frame(0x03, records))
        assertNotNull(f)
        assertEquals(0x03, f!!.type)
        assertArrayEquals(records, f.payload)
        assertEquals(241, f.payload.size)
    }

    @Test fun overheadIsThreeBytesAndNoPayloadByteIsDropped() {
        // Regression: the old code stripped 4 bytes after the frame byte and dropped
        // one real data byte per packet. The first payload byte must survive.
        val payload = byteArrayOf(0xEA.toByte(), 0x07, 0x0B, 0x1D) // e.g. year 2026 in a record
        val f = PacketFraming.parseFrame(frame(0x03, payload))!!
        assertEquals(0xEA, f.payload[0].toInt() and 0xFF)
        assertArrayEquals(payload, f.payload)
    }

    @Test fun recordBytesAreNeverReadAsAPacketCount() {
        // 0x07EA0000 = 132775936, one of the bogus "counts" from the field log; here
        // it is just payload and must come through untouched.
        val payload = byteArrayOf(0x00, 0x00, 0xEA.toByte(), 0x07, 0x01, 0x02)
        val f = PacketFraming.parseFrame(frame(0x03, payload))!!
        assertArrayEquals(payload, f.payload)
    }

    @Test fun nonFramesAreRejected() {
        assertNull(PacketFraming.parseFrame(byteArrayOf())) // empty
        assertNull(PacketFraming.parseFrame(byteArrayOf(0xAE.toByte(), 0x03))) // too short
        assertNull(PacketFraming.parseFrame(byteArrayOf(0x03, 0x01, 0x01, 0x00))) // no 0xAE
    }

    @Test fun aLengthLargerThanWhatArrivedYieldsWhatIsThere() {
        val truncated = byteArrayOf(0xAE.toByte(), 0x03, 100, 1, 2, 3)
        val f = PacketFraming.parseFrame(truncated)!!
        assertArrayEquals(byteArrayOf(1, 2, 3), f.payload)
    }

    @Test fun trailingBytesBeyondTheLengthAreIgnored() {
        val padded = byteArrayOf(0xAE.toByte(), 0x03, 2, 9, 8, 7, 7, 7)
        val f = PacketFraming.parseFrame(padded)!!
        assertArrayEquals(byteArrayOf(9, 8), f.payload)
    }

    @Test fun otherMessageTypesAreParsedWithTheirType() {
        val f = PacketFraming.parseFrame(frame(0x09, byteArrayOf(1, 2, 3)))!!
        assertEquals(0x09, f.type)
    }

    @Test fun reassemblingAWholeFileGivesBackEveryByte() {
        // A 1,000-byte file split into 241-byte frames: concatenating the payloads in
        // order must reproduce the file exactly, whichever way records fall across frames.
        val file = ByteArray(1000) { (it * 7 % 256).toByte() }
        val frames = file.toList().chunked(241).map { frame(0x03, it.toByteArray()) }
        val out = java.io.ByteArrayOutputStream()
        var received = 0L
        for (packet in frames) {
            val f = PacketFraming.parseFrame(packet)!!
            out.write(f.payload)
            received += f.payload.size
        }
        assertEquals(1000L, received)
        assertArrayEquals(file, out.toByteArray())
    }
}
