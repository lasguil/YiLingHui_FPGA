package com.efinity.ti60

import android.content.res.AssetManager
import java.io.*
import java.net.*
import java.util.UUID
import java.util.concurrent.*
import kotlin.concurrent.thread

interface HttpBackend {
    fun frame(): CompleteFrame?
    fun status(): String
    fun registers(): String
    fun session(body: String)
    fun api(path: String, body: String): String
    fun streamError()
    fun clientDelta(delta: Long)
    fun frameSent()
}
class LocalHttpServer(private val html: String, private val backend: HttpBackend, preferredPort: Int = 8080, private val assets: AssetManager? = null): AutoCloseable {
    private val listener=openListener(preferredPort)
    val port get()=listener.localPort
    val token=UUID.randomUUID().toString()
    val origin get()="http://127.0.0.1:$port"
    private val workers=ThreadPoolExecutor(0,8,30,TimeUnit.SECONDS,SynchronousQueue<Runnable>())
    private val watchdog=Executors.newSingleThreadScheduledExecutor()
    private val streamCount=java.util.concurrent.atomic.AtomicInteger()
    private val active=ConcurrentHashMap.newKeySet<Socket>()
    private val acceptor=thread(name="ti60-http") {
        while(!listener.isClosed) {
            try {
                val s=listener.accept(); s.soTimeout=3000; active.add(s)
                try { workers.execute { serve(s) } } catch(e: RejectedExecutionException) { active.remove(s); s.close() }
            } catch(e: IOException) { if(listener.isClosed) break }
        }
    }
    private fun serve(s: Socket) {
        var guard: ScheduledFuture<*>?=null
        try { s.use {
            guard=watchdog.schedule({ s.close() },5,TimeUnit.SECONDS)
            val input=s.getInputStream(); val header=ByteArrayOutputStream(); var match=0
            val terminator=byteArrayOf(13,10,13,10)
            while(match<4) {
                val c=input.read(); if(c<0) return
                require(header.size()<8192); header.write(c)
                match=if(c==terminator[match].toInt()) match+1 else if(c==13) 1 else 0
            }
            val lines=header.toString("US-ASCII").split("\r\n")
            val request=lines[0].split(' '); require(request.size==3)
            val method=request[0]; val path=request[1].substringBefore('?')
            val h=lines.drop(1).filter { ':' in it }.associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
            if(h["host"]!="127.0.0.1:$port") { reply(s,403,"text/plain","Host 拒绝".toByteArray()); return }
            if(h.containsKey("transfer-encoding")) { reply(s,400,"text/plain",byteArrayOf()); return }
            if(method=="POST") {
                if(h["x-session-token"]!=token || h["origin"]!=origin) { reply(s,403,"text/plain","来源拒绝".toByteArray()); return }
                val n=h["content-length"]?.toIntOrNull() ?: -1; require(n in 0..65536)
                val body=ByteArray(n); var at=0
                while(at<n) { val read=input.read(body,at,n-at); require(read>0); at+=read }
                if(path=="/api/agent/plan" || path=="/api/agent/scene_plan") { guard?.cancel(false); guard=watchdog.schedule({ s.close() },agentPlanWatchdogSeconds,TimeUnit.SECONDS) }
                else if(path=="/api/control/action" || path=="/api/control/set") { guard?.cancel(false); guard=watchdog.schedule({ s.close() },10,TimeUnit.SECONDS) }
                else if(path=="/api/link-probe") { guard?.cancel(false); guard=watchdog.schedule({ s.close() },25,TimeUnit.SECONDS) }
                when(path) {
                    "/api/session" -> { backend.session(String(body,Charsets.UTF_8)); reply(s,200,"application/json",backend.status().toByteArray()) }
                    "/api/decode-error" -> { backend.streamError(); reply(s,200,"application/json",backend.status().toByteArray()) }
                    "/api/agent/config", "/api/agent/plan", "/api/agent/scene_plan", "/api/agent/execute", "/api/agent/run", "/api/agent/cancel", "/api/agent/clear", "/api/control/action", "/api/control/set", "/api/link-probe" -> {
                        val result=backend.api(path,String(body,Charsets.UTF_8))
                        val ok=try { org.json.JSONObject(result).optBoolean("ok",true) } catch(_:Exception) { true }
                        reply(s,if(ok)200 else 502,"application/json; charset=utf-8",result.toByteArray())
                    }
                    else -> { reply(s,404,"text/plain",byteArrayOf()); return }
                }; return
            }
            if(method!="GET") { reply(s,405,"text/plain",byteArrayOf()); return }
            when(path) {
                "/" -> reply(s,200,"text/html; charset=utf-8",html.replace("__TOKEN__",token).toByteArray())
                "/style.css" -> reply(s,200,"text/css; charset=utf-8",assetBytes("style.css") ?: byteArrayOf())
                "/app.js" -> reply(s,200,"text/javascript; charset=utf-8",assetBytes("app.js") ?: byteArrayOf())
                "/fonts/plexmono-400.woff2","/fonts/plexmono-600.woff2","/fonts/plexsans-600.woff2" ->
                    reply(s,200,"font/woff2",assetBytes(path.trimStart('/')) ?: byteArrayOf())
                "/api/status", "/export.json" -> reply(s,200,"application/json; charset=utf-8",backend.status().toByteArray())
                "/api/regs" -> reply(s,200,"application/json",backend.registers().toByteArray())
                "/api/link-state" -> reply(s,200,"application/json",backend.api("/api/link-state","{}").toByteArray())
                "/api/link-log" -> reply(s,200,"text/plain; charset=utf-8",Diagnostics.dump().lineSequence().filter {
                    it.matches(Regex("^\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s+(app |wifi |connectBoard|connect:|reconnect |session |workers:|control:|dest config|video:|engine close|permission |bridge connect).*"))
                }.joinToString("\n").toByteArray())
                "/api/agent/status" -> reply(s,200,"application/json",backend.api("/api/agent/status","{}").toByteArray())
                "/api/agent/history" -> reply(s,200,"application/json",backend.api("/api/agent/history","{}").toByteArray())
                "/snapshot.jpg" -> { val f=backend.frame(); reply(s,if(f==null)503 else 200,if(f==null)"text/plain" else "image/jpeg",f?.jpeg ?: "暂无完整 JPEG".toByteArray()) }
                "/stream" -> { guard?.cancel(false); guard=null; stream(s) }
                else -> reply(s,404,"text/plain",byteArrayOf())
            }
        } } catch(e: Exception) { try { if(!s.isClosed) reply(s,400,"text/plain",(e.message ?: "请求失败").toByteArray()) } catch(_: Exception) { } }
        finally { guard?.cancel(false); active.remove(s); try { s.close() } catch(_: Exception) { } }
    }
    private fun assetBytes(name: String): ByteArray? = try {
        assets?.open(name)?.use { it.readBytes() }
    } catch(e: Exception) { null }
    private fun reply(s: Socket, code: Int, type: String, data: ByteArray) {
        val reason=when(code) {200->"OK";503->"Service Unavailable";403->"Forbidden";404->"Not Found";405->"Method Not Allowed";else->"Bad Request"}
        val out=s.getOutputStream()
        out.write(("HTTP/1.1 $code $reason\r\nContent-Type: $type\r\nContent-Length: ${data.size}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' blob:; font-src 'self'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n").toByteArray())
        out.write(data); out.flush()
    }
    private fun stream(s: Socket) {
        // Dedicated bounded worker per reader; watchdog closes stalled writes.
        if(streamCount.incrementAndGet()>4) { streamCount.decrementAndGet(); reply(s,503,"text/plain","最多四个视频读者".toByteArray()); return }
        backend.clientDelta(1)
        try {
            val out=BufferedOutputStream(s.getOutputStream(),16384)
            out.write("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray()); out.flush()
            var last: CompleteFrame?=null
            var lastWrite=System.nanoTime()
            while(!s.isClosed && !listener.isClosed) {
                val f=backend.frame()
                if(f==null || f===last) {
                    // A disconnected reader cannot be detected by isClosed alone.
                    if(System.nanoTime()-lastWrite>5_000_000_000L) break
                    Thread.sleep(8); continue
                }
                val guard=watchdog.schedule({ s.close() },2,TimeUnit.SECONDS)
                try {
                    if(last==null) out.write("--frame\r\n".toByteArray())
                    out.write("Content-Type: image/jpeg\r\nContent-Length: ${f.jpeg.size}\r\nX-Frame-Id: ${f.id}\r\n\r\n".toByteArray())
                    // WebView needs the next MIME boundary to publish this JPEG,
                    // even when Content-Length is present. Do not wait for another frame.
                    out.write(f.jpeg); out.write("\r\n--frame\r\n".toByteArray()); out.flush()
                    backend.frameSent(); last=f
                    lastWrite=System.nanoTime()
                } finally { guard.cancel(false) }
            }
        } finally { backend.clientDelta(-1); streamCount.decrementAndGet() }
    }
    override fun close() { listener.close(); active.forEach { try { it.close() } catch(_: Exception) { } }; workers.shutdownNow(); workers.awaitTermination(1500,TimeUnit.MILLISECONDS); watchdog.shutdownNow(); acceptor.join(500) }
    companion object {
        internal const val agentPlanWatchdogSeconds=210L
        private fun openListener(preferredPort: Int): ServerSocket {
            try { return ServerSocket(preferredPort,8,InetAddress.getByName("127.0.0.1")) }
            catch(e: BindException) { return ServerSocket(0,8,InetAddress.getByName("127.0.0.1")) }
        }
    }
}
