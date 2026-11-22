package com.efinity.ti60

import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest

class ProtocolTest {
    private fun fixture(): List<VideoPacket> = File("../fixtures/mjpeg_v2_frame_1").listFiles()!!
        .filter { it.extension=="udp" }.sortedBy { it.name }.map { VideoPacket.parse(it.readBytes()) }
    private fun jpeg(): ByteArray = fixture().flatMap { it.payload.asIterable() }.toByteArray()
    private fun packet(id: Long=0, data: ByteArray=jpeg())=VideoPacket(id,0,0,0,3,data)
    private fun failed(f: ()->Unit) { try { f(); fail("Expected rejection") } catch(_: IllegalArgumentException) { } catch(_: IllegalStateException) { } }
    @Test fun realFixtureShaAndSize() {
        val a=JpegAssembler(); var result: CompleteFrame?=null
        fixture().forEachIndexed { i,p -> a.accept(p,1_000_000L+i*1000)?.let { result=it } }
        assertNotNull(result); assertEquals(JpegSize(1280,720),result!!.size)
        val hash=MessageDigest.getInstance("SHA-256").digest(result!!.jpeg).joinToString("") { "%02x".format(it) }
        assertEquals("98a32ec1139ae83312219f0d1d5b91e718b1bbf67263747bc00b11117f5a76a0",hash)
    }
    @Test fun intactFrameWithContinuousProgressSurvivesDeadline() {
        val parts=fixture()
        val fast=JpegAssembler(); var fastFrame: CompleteFrame?=null
        val slow=JpegAssembler(); var slowFrame: CompleteFrame?=null
        parts.forEachIndexed { i,p ->
            fast.accept(p,1_000_000L+i*1_000_000L)?.let { fastFrame=it }
            slow.accept(p,1_000_000L+i*2_000_000L)?.let { slowFrame=it }
        }
        assertNotNull(fastFrame)
        assertNotNull(slowFrame)
        assertEquals(0,slow.stats.incomplete)
        assertEquals(0,slow.stats.duplicate)
    }
    @Test fun bigEndianUnsignedAndBounds() {
        val d=File("../fixtures/mjpeg_v2_frame_1/0000.udp").readBytes()
        ByteBuffer.wrap(d).putInt(4,-1).putInt(16,Int.MIN_VALUE)
        val p=VideoPacket.parse(d); assertEquals(0xffffffffL,p.id); assertEquals(0x80000000L,p.timestamp)
        ByteBuffer.wrap(d).putInt(12,-1); failed { VideoPacket.parse(d) }
        failed { VideoPacket.parse(ByteArray(20)) }; failed { VideoPacket.parse(ByteArray(1473)) }
    }
    @Test fun rejectsVersionsMagicTotalFlags() {
        val d=File("../fixtures/mjpeg_v2_frame_1/0000.udp").readBytes()
        for((offset,value) in listOf(0 to 0,2 to 1,3 to 8,10 to 0,11 to 0)) {
            val x=d.clone(); x[offset]=value.toByte(); failed { VideoPacket.parse(x) }
        }
    }
    @Test fun singleFrameZeroAndWrap() {
        val a=JpegAssembler(); assertNotNull(a.accept(packet(0xffffffffL),1)); assertNotNull(a.accept(packet(0),2))
        assertTrue(newer(0,0xffffffffL)); assertFalse(newer(0xffffffffL,0)); assertFalse(newer(0,0))
    }
    @Test fun eofFirstAndOutOfOrder() {
        val a=JpegAssembler(); val parts=fixture(); var f: CompleteFrame?=null
        parts.reversed().forEachIndexed { i,p -> a.accept(p,1000L+i)?.let { f=it } }
        assertNotNull(f); assertEquals(76L,a.stats.reordered)
    }
    @Test fun duplicateAndConflict() {
        val parts=fixture(); val a=JpegAssembler()
        a.accept(parts[0],1); a.accept(parts[0],2); assertEquals(1,a.stats.duplicate)
        val bytes=parts[0].payload.clone(); bytes[0]=0
        a.accept(parts[0].copy(payload=bytes),3)
        parts.drop(1).forEach { assertNull(a.accept(it,4)) }; assertEquals(1,a.stats.invalid)
    }
    @Test fun overlapAndMissingSofEof() {
        val parts=fixture(); val a=JpegAssembler()
        a.accept(parts[0],1); assertNull(a.accept(parts[1].copy(offset=10),2)); assertEquals(1,a.stats.invalid)
        val b=JpegAssembler(); parts.drop(1).forEach { assertNull(b.accept(it,100)) }; b.expire(101_000_000); assertEquals(1,b.stats.incomplete)
        val c=JpegAssembler(); parts.dropLast(1).forEach { assertNull(c.accept(it,100)) }; c.expire(101_000_000); assertEquals(1,c.stats.incomplete)
        val raw=File("../fixtures/mjpeg_v2_frame_1/0000.udp").readBytes(); raw[3]=0; failed { VideoPacket.parse(raw) }
    }
    @Test fun adjacentInterleave() {
        val parts=fixture(); val a=JpegAssembler(); var count=0
        for(p in parts.dropLast(1)) { if(a.accept(p,1)!=null)count++; if(a.accept(p.copy(id=2),2)!=null)count++ }
        assertNotNull(a.accept(parts.last(),3)); assertNotNull(a.accept(parts.last().copy(id=2),4)); assertEquals(2,a.stats.complete)
    }
    @Test fun timeoutAndWindowAndRecovery() {
        val a=JpegAssembler(); val p=fixture()[0]
        for(id in 1L..5L) a.accept(p.copy(id=id),id)
        assertEquals(2,a.stats.incomplete); a.expire(101_000_000); assertEquals(5,a.stats.incomplete)
        assertNotNull(a.accept(packet(6),102_000_000))
        failed { JpegAssembler(window=5) }; failed { JpegAssembler(timeoutMs=19) }
    }
    @Test fun deviceRestartAfterSilenceAndContinuousPackets() {
        val a=JpegAssembler(); a.accept(packet(100),1)
        assertNotNull(a.accept(packet(0),3_000_000_000)); assertEquals(1,a.stats.restarts)
        val b=JpegAssembler(); b.accept(packet(100),1); b.accept(packet(1),1_000_000_000)
        assertNotNull(b.accept(packet(2),2_100_000_000)); assertEquals(1,b.stats.restarts)
    }
    @Test fun boundedWholeFrameGaps() {
        val a=JpegAssembler(); for(id in listOf(0L,1L,3L,4L,5L,6L)) a.accept(packet(id),id+100)
        assertEquals(1,a.stats.missing)
        val b=JpegAssembler(); b.accept(packet(0xffffffffL),100); b.accept(packet(0),101); b.accept(packet(4),102)
        assertEquals(1,b.stats.missing) // ID 1 finalized; 2,3 still inside window
    }
    @Test fun malformedJpegAndDimensionLimit() {
        val j=jpeg(); val a=JpegAssembler()
        val corrupt=j.clone(); corrupt[0]=0; assertNull(a.accept(packet(data=corrupt),1))
        failed { jpegSize(byteArrayOf(-1,-40,-1,-39)) }
        val large=j.clone(); var p=2
        while(p<large.size) { val marker=large[p+1].toInt() and 255; val n=((large[p+2].toInt() and 255) shl 8) or (large[p+3].toInt() and 255)
            if(marker==192) { large[p+5]=0x7f; large[p+6]=0xff.toByte(); break }; p+=2+n }
        failed { jpegSize(large) }
    }
    @Test fun controlExactBytesAndAckMatching() {
        val request=ControlProtocol.read(0x1234,0)
        assertEquals("435401001234000000000000",request.joinToString("") { "%02x".format(it) })
        val ack=request.clone(); ack[3]=2; ByteBuffer.wrap(ack).putInt(8,0x4e423031)
        assertEquals(0x4e423031L,ControlProtocol.response(ack,12,0x1234,0))
        assertNull(ControlProtocol.response(ack,12,1,0)); ack[3]=5; assertNull(ControlProtocol.response(ack,12,0x1234,0))
        ack[3]=3; failed { ControlProtocol.response(ack,12,0x1234,0) }
    }
}
