package com.efinity.ti60

import java.nio.ByteBuffer
import java.nio.ByteOrder

fun newer(a: Long, b: Long): Boolean = ((a - b) and 0xffffffffL) in 1..0x7fffffffL

data class VideoPacket(val id: Long, val index: Int, val offset: Int, val timestamp: Long,
                       val flags: Int, val payload: ByteArray) {
    companion object {
        fun parse(data: ByteArray, length: Int = data.size, max: Int = 4*1024*1024): VideoPacket {
            require(length in 21..1472 && length <= data.size) { "非法 UDP 长度" }
            val b = ByteBuffer.wrap(data, 0, length).order(ByteOrder.BIG_ENDIAN)
            require(b.short.toInt() and 65535 == 0x5649) { "magic" }
            val version = b.get().toInt() and 255
            require(version == 2) { if(version == 1) "RGB565 v1 尚不支持" else "version" }
            val flags = b.get().toInt() and 255
            require(flags and 0xfc == 0) { "flags" }
            val id = b.int.toLong() and 0xffffffffL
            val index = b.short.toInt() and 65535
            require(b.short.toInt() and 65535 == 65535) { "pkt_total" }
            val off = b.int.toLong() and 0xffffffffL
            val ts = b.int.toLong() and 0xffffffffL
            require(off + length - 20 <= max && index < max) { "offset/size" }
            require(flags and 1 == 0 || (index == 0 && off == 0L)) { "SOF" }
            require(index != 0 || (off == 0L && flags and 1 != 0)) { "missing SOF" }
            return VideoPacket(id, index, off.toInt(), ts, flags, data.copyOfRange(20,length))
        }
    }
}

data class JpegSize(val width: Int, val height: Int)
/** Header scan only: JPEG bytes are never decoded or encoded here. */
fun jpegSize(j: ByteArray): JpegSize {
    fun u(i: Int) = j[i].toInt() and 255
    require(j.size >= 12 && u(0)==255 && u(1)==216 && u(j.size-2)==255 && u(j.size-1)==217) { "JPEG SOI/EOI" }
    var p=2; var size: JpegSize?=null
    while(p < j.size-2) {
        require(u(p++)==255) { "JPEG marker" }
        while(p<j.size && u(p)==255) p++
        require(p<j.size)
        val marker=u(p++)
        require(marker!=0 && marker!=216 && marker!=217)
        if(marker==1 || marker in 208..215) continue
        require(p+2<=j.size)
        val n=(u(p) shl 8) or u(p+1)
        require(n>=2 && p+n<=j.size-2) { "JPEG segment" }
        if(marker in setOf(192,193,194,195,197,198,199,201,202,203,205,206,207)) {
            require(n>=8)
            val h=(u(p+3) shl 8) or u(p+4); val w=(u(p+5) shl 8) or u(p+6)
            require(w in 1..4096 && h in 1..4096 && w.toLong()*h<=8388608) { "JPEG dimensions" }
            val components=u(p+7); require(components in 1..4 && n==8+3*components)
            size=JpegSize(w,h)
        }
        if(marker==218) { require(size!=null && n>=6 && p+n<j.size-2); return size }
        p+=n
    }
    error("JPEG missing SOS/SOF")
}

data class CompleteFrame(val id: Long, val jpeg: ByteArray, val size: JpegSize, val completedNs: Long, val assemblyMs: Double)
class AssemblyStats {
    @Volatile var complete=0L; @Volatile var incomplete=0L; @Volatile var missing=0L; @Volatile var duplicate=0L
    @Volatile var reordered=0L; @Volatile var invalid=0L; @Volatile var stale=0L; @Volatile var restarts=0L
    @Volatile var timeoutDrops=0L; @Volatile var windowDrops=0L
}
/** One receiver owns this object; immutable completed buffers pass to readers. */
class JpegAssembler(val timeoutMs: Long = 100, val window: Int = 3, val maxBytes: Int = 4*1024*1024) {
    init { require(timeoutMs in 20..500 && window in 1..4 && maxBytes in 1024..4*1024*1024) }
    val stats=AssemblyStats()
    private data class Pending(val first: Long, var lastProgress: Long = first, val packets: MutableMap<Int,VideoPacket> = HashMap(), var eof: Int?=null, var bytes: Int=0, var high: Int=-1)
    private val pending=LinkedHashMap<Long,Pending>()
    private val retired=LinkedHashMap<Long,Long>()
    private var last: Long?=null
    private var lastPublish=0L
    private var highSeen: Long?=null
    private var finalized: Long?=null
    private val observed=HashSet<Long>()
    private var lastPacket=0L
    fun expire(now: Long) {
        val it=pending.iterator()
        while(it.hasNext()) { val e=it.next(); if(now-e.value.lastProgress>timeoutMs*1000000 || now-e.value.first>2_000_000_000L) { stats.incomplete++; stats.timeoutDrops++; retired[e.key]=now; it.remove() } }
        while(retired.size>64) retired.remove(retired.keys.first())
    }
    fun accept(p: VideoPacket, now: Long=System.nanoTime()): CompleteFrame? {
        require(p.offset>=0 && p.offset.toLong()+p.payload.size<=maxBytes && p.payload.isNotEmpty())
        expire(now)
        // A long silent interval plus SOF permits a fresh device epoch.
        if(p.flags and 1 != 0 && lastPacket!=0L && (now-lastPacket>2_000_000_000L || (last!=null && !newer(p.id,last!!) && p.id!=last && now-lastPublish>2_000_000_000L))) {
            pending.clear(); retired.clear(); last=null; highSeen=null; finalized=null; observed.clear(); stats.restarts++
        }
        lastPacket=now
        if(retired.containsKey(p.id)) { stats.stale++; return null }
        if(last==p.id) { stats.duplicate++; return null }
        if(finalized!=null && newer(p.id,finalized!!)) observed.add(p.id)
        if(last!=null && !newer(p.id,last!!)) { stats.stale++; return null }
        if(highSeen==null) { highSeen=p.id; finalized=(p.id-1) and 0xffffffffL }
        else if(newer(p.id,highSeen!!)) {
            val distance=(p.id-highSeen!!) and 0xffffffffL
            if(distance>10000) { highSeen=p.id; finalized=(p.id-1) and 0xffffffffL; observed.clear(); stats.restarts++ }
            else highSeen=p.id
        }
        observed.add(p.id)
        // Delay finalization by `window` frame IDs; an observed partial frame is
        // incomplete, not a wholly missing frame. No gaps before the first ID.
        val limit=(highSeen!!-window) and 0xffffffffL
        if(finalized!=null && newer(limit,finalized!!)) {
            val distance=(limit-finalized!!) and 0xffffffffL
            if(distance<=10000) for(i in 1..distance) {
                val id=(finalized!!+i) and 0xffffffffL
                if(!observed.remove(id)) stats.missing++
            }
            finalized=limit
        }
        observed.removeAll { it==finalized || !newer(it,finalized!!) }
        var f=pending[p.id]
        if(f==null) {
            if(pending.size>=window) { val id=pending.keys.first(); pending.remove(id); retired[id]=now; stats.incomplete++; stats.windowDrops++ }
            f=Pending(now); pending[p.id]=f
        }
        fun bad(): CompleteFrame? { pending.remove(p.id); retired[p.id]=now; stats.invalid++; stats.incomplete++; return null }
        val old=f.packets[p.index]
        if(old!=null) {
            if(old.offset==p.offset && old.flags==p.flags && old.timestamp==p.timestamp && old.payload.contentEquals(p.payload)) stats.duplicate++ else return bad()
            return null
        }
        if(f.eof!=null && p.index>=f.eof!!) return bad()
        if(p.flags and 2 != 0) {
            val count=p.index+1
            if(f.eof!=null && f.eof!=count || f.packets.keys.any { it>=count }) return bad()
            f.eof=count
        }
        val end=p.offset+p.payload.size
        if(end>maxBytes || f.bytes+p.payload.size>maxBytes || f.packets.size>=8192) return bad()
        if(f.packets.values.any { p.offset<it.offset+it.payload.size && end>it.offset }) return bad()
        if(p.index<f.high) stats.reordered++
        f.high=maxOf(f.high,p.index); f.bytes+=p.payload.size; f.packets[p.index]=p; f.lastProgress=now
        val count=f.eof ?: return null
        if(f.packets.size!=count || (0 until count).any { !f.packets.containsKey(it) }) return null
        val sorted=f.packets.values.sortedBy { it.offset }
        var cursor=0
        for(part in sorted) { if(part.offset!=cursor) return bad(); cursor+=part.payload.size }
        if(f.packets[0]!!.flags and 1==0 || sorted.last().index!=count-1) return bad()
        val data=ByteArray(cursor)
        sorted.forEach { it.payload.copyInto(data,it.offset) }
        val size=try { jpegSize(data) } catch(e: IllegalArgumentException) { return bad() } catch(e: IllegalStateException) { return bad() }
        pending.remove(p.id); retired[p.id]=now; last=p.id; lastPublish=now; stats.complete++
        return CompleteFrame(p.id,data,size,now,(now-f.first)/1e6)
    }
}

object ControlProtocol {
    val registers=listOf(0x0000,0x0014,0x0018,0x0020,0x0024,0x0028,0x002c,0x0038,0x003c,0x0040,
        0x0120,0x0124,0x0128,0x012c,0x0130,0x0134,0x0138,0x013c,0x0140,0x0144,0x0148,0x0150)
    fun read(seq: Int, reg: Int): ByteArray = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        .putShort(0x4354).put(1).put(0).putShort(seq.toShort()).putShort(reg.toShort()).putInt(0).array()
    fun write(seq: Int, reg: Int, value: Long): ByteArray = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        .putShort(0x4354).put(1).put(1).putShort(seq.toShort()).putShort(reg.toShort()).putInt(value.toInt()).array()
    data class Reply(val op: Int, val value: Long)
    fun reply(data: ByteArray, n: Int, seq: Int, reg: Int): Reply? {
        if(n!=12) return null
        val b=ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        if(b.short.toInt() and 65535 != 0x4354 || b.get().toInt()!=1) return null
        val op=b.get().toInt()
        if(b.short.toInt() and 65535 != seq || b.short.toInt() and 65535 != reg) return null
        if(op !in 2..3) return null
        return Reply(op,b.int.toLong() and 0xffffffffL)
    }
    fun response(data: ByteArray, n: Int, seq: Int, reg: Int): Long? {
        if(n!=12) return null
        val b=ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        if(b.short.toInt() and 65535 != 0x4354 || b.get().toInt()!=1) return null
        val op=b.get().toInt()
        if(b.short.toInt() and 65535 != seq || b.short.toInt() and 65535 != reg) return null
        if(op==3) error("NACK")
        if(op!=2) return null
        return b.int.toLong() and 0xffffffffL
    }
}

object ACommandProtocol {
    const val bridgeId=0x4A374331L
    const val regBridgeId=0x0120
    const val regToken=0x0128
    const val regState=0x012C
    const val regMeta=0x0180
    const val regData=0x0184
    const val regCommit=0x01BC
    const val maxPayload=54
    /** Words after metadata are little-endian packed, as required by the board2 bridge. */
    fun stages(kind:Int,payload:ByteArray):List<Pair<Int,Long>> {
        require(kind in 0..255 && payload.size<=maxPayload) { "invalid A command" }
        val words=IntArray((payload.size+3)/4)
        payload.forEachIndexed { i,b -> words[i/4]=words[i/4] or ((b.toInt() and 255) shl ((i%4)*8)) }
        return listOf(regMeta to ((kind shl 8) or payload.size).toLong())+
            words.mapIndexed { i,v -> (regData+4*i) to (v.toLong() and 0xffffffffL) }
    }
    fun nextToken(current:Long):Long=((current+1) and 0xffffffffL).let { if(it==0L) 1L else it }
}

/** Manual controls use UI_SET, never the WAVE-PRO-only gesture pause packet. */
object DeviceParameters {
    data class Spec(val id:Int,val max:Int)
    val specs=mapOf("model" to Spec(1,28), "table" to Spec(2,12), "ai" to Spec(3,100),
        "fx" to Spec(4,100), "wave" to Spec(5,2), "pause" to Spec(6,1),
        "sat" to Spec(7,200), "keep" to Spec(8,1), "keep_range" to Spec(9,2)) +
        (0..5).associate { "b$it" to Spec(10+it,255) }
    fun payload(field:String,raw:Any?):ByteArray {
        val spec=specs[field] ?: throw IllegalArgumentException("未知参数")
        val value=raw as? Int ?: throw IllegalArgumentException("参数必须为整数")
        require(value in 0..spec.max) { "参数超出范围" }
        return byteArrayOf(spec.id.toByte(),value.toByte())
    }
}
