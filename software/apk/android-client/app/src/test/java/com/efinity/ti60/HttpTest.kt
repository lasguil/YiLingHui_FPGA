package com.efinity.ti60

import org.junit.Assert.*
import org.junit.Test
import java.net.*
import java.util.concurrent.atomic.AtomicLong

class HttpTest {
    class Backend: HttpBackend {
        @Volatile var latest: CompleteFrame?=null
        @Volatile var apiPath=""; @Volatile var apiBody=""; var apiResult="{\"ok\":true}"
        val sent=AtomicLong(); val clients=AtomicLong(); var sessions=0
        override fun frame()=latest
        override fun status()="{\"ok\":true}"
        override fun registers()="{}"
        override fun session(body: String) { sessions++ }
        override fun api(path: String, body: String):String { apiPath=path; apiBody=body; return apiResult }
        override fun streamError() {}
        override fun clientDelta(delta: Long) { clients.addAndGet(delta) }
        override fun frameSent() { sent.incrementAndGet() }
    }
    private fun get(server: LocalHttpServer,path: String): HttpURLConnection = URL(server.origin+path).openConnection().let { it as HttpURLConnection }.apply { connectTimeout=1500; readTimeout=3000 }
    private fun post(server:LocalHttpServer,path:String,body:String,token:String=server.token):String =
        Socket("127.0.0.1",server.port).use { socket ->
            socket.soTimeout=3000
            val bytes=body.toByteArray(Charsets.UTF_8)
            socket.getOutputStream().write(("POST $path HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nOrigin: ${server.origin}\r\nX-Session-Token: $token\r\nContent-Length: ${bytes.size}\r\n\r\n").toByteArray()+bytes)
            socket.getInputStream().bufferedReader().readText()
        }
    @Test fun everyPagePostEndpointIsRouted() {
        val html=listOf(java.io.File("src/main/assets/index.html"),java.io.File("app/src/main/assets/index.html")).first { it.exists() }.readText()
        val paths=Regex("post\\('([^']+)'").findAll(html).map { it.groupValues[1] }.toSet()
        assertTrue(paths.contains("/api/control/set"))
        LocalHttpServer("",Backend(),0).use { server ->
            paths.forEach { path -> assertTrue("Missing page route $path",post(server,path,"{}").startsWith("HTTP/1.1 200")) }
        }
        Regex("data-action=\"([^\"]+)\"").findAll(html).forEach {
            assertTrue("Unknown page action ${it.groupValues[1]}",it.groupValues[1] in LiveAgent.allowed)
        }
    }
    @Test fun absoluteParametersReachBackendAndPreserveFailureReceipt() {
        val backend=Backend()
        LocalHttpServer("",backend,0).use { server ->
            for((field,value) in DeviceParameters.specs.map { (field,spec) -> field to spec.max }) {
                val body=org.json.JSONObject().put("field",field).put("value",value).toString()
                assertTrue(post(server,"/api/control/set",body).startsWith("HTTP/1.1 200"))
                assertEquals("/api/control/set",backend.apiPath); assertEquals(body,backend.apiBody)
            }
            backend.apiResult="{\"ok\":false,\"state\":\"a_rejected\",\"token\":123}"
            val response=post(server,"/api/control/set","{\"field\":\"model\",\"value\":0}")
            assertTrue(response.startsWith("HTTP/1.1 502")); assertTrue(response.endsWith(backend.apiResult))
            backend.apiPath=""
            assertTrue(post(server,"/api/control/set","{}","bad").startsWith("HTTP/1.1 403"))
            assertEquals("",backend.apiPath)
        }
    }
    @Test fun removedWipeEndpointCannotReachBackend() {
        val backend=Backend()
        LocalHttpServer("",backend,0).use { server ->
            assertTrue(post(server,"/api/control/wipe","{\"x\":0.9}").startsWith("HTTP/1.1 404"))
            assertEquals("",backend.apiPath)
        }
    }
    @Test fun endpointsAndPortFallbackAndShutdown() {
        val backend=Backend()
        LocalHttpServer("hello __TOKEN__",backend,0).use { server ->
            assertEquals("hello "+server.token,get(server,"/").inputStream.bufferedReader().readText())
            assertEquals(503,get(server,"/snapshot.jpg").responseCode)
            assertEquals("{\"ok\":true}",get(server,"/api/status").inputStream.bufferedReader().readText())
            LocalHttpServer("",backend,server.port).use { other-> assertNotEquals(server.port,other.port) }
            assertEquals(404,get(server,"/not-found").responseCode)
        }
    }
    @Test fun csrfAndHostRejected() {
        val backend=Backend()
        LocalHttpServer("",backend,0).use { server ->
            // Raw socket avoids URLConnection's restricted Origin header handling.
            fun post(origin: String, token: String, host: String="127.0.0.1:${server.port}"): String {
                return Socket("127.0.0.1",server.port).use { s ->
                    s.soTimeout=2000
                    s.getOutputStream().write(("POST /api/session HTTP/1.1\r\nHost: $host\r\nOrigin: $origin\r\nX-Session-Token: $token\r\nContent-Length: 2\r\n\r\n{}").toByteArray())
                    s.getInputStream().bufferedReader().readLine()
                }
            }
            assertTrue(post("https://evil.example",server.token).contains("403"))
            assertTrue(post(server.origin,"bad").contains("403"))
            assertTrue(post(server.origin,server.token,"evil.example").contains("403"))
            assertTrue(post(server.origin,server.token).contains("200")); assertEquals(1,backend.sessions)
        }
    }
    @Test fun slowClientsDontBlockNewFramesAndShutdownClosesSockets() {
        val backend=Backend(); val server=LocalHttpServer("",backend,0)
        val slow=List(3) {
            Socket("127.0.0.1",server.port).apply {
                receiveBufferSize=1024; soTimeout=3500
                getOutputStream().write("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n".toByteArray())
            }
        }
        val fast=Socket("127.0.0.1",server.port).apply { soTimeout=3500; getOutputStream().write("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n".toByteArray()) }
        try {
            backend.latest=CompleteFrame(1,ByteArray(1024*1024),JpegSize(1280,720),System.nanoTime(),0.0)
            val input=fast.getInputStream(); val buffer=ByteArray(65536); var count=0
            while(count<1024*1024) { val n=input.read(buffer); assertTrue(n>0); count+=n }
            assertEquals(200,get(server,"/api/status").responseCode)
            assertTrue(backend.sent.get()>=1)
        } finally { server.close(); slow.forEach { it.close() }; fast.close() }
        assertEquals(0,backend.clients.get())
    }
    @Test fun closingUdpSocketStopsBlockedReceiver() {
        val socket=DatagramSocket(0,InetAddress.getLoopbackAddress())
        val receiver=Thread { try { socket.receive(DatagramPacket(ByteArray(65536),65536)) } catch(_: SocketException) { } }
        receiver.start(); socket.close(); receiver.join(500); assertFalse(receiver.isAlive)
    }
    @Test fun singleFrameHasBoundaryWithoutWaitingForAnotherFrame() {
        val backend=Backend()
        val jpeg=byteArrayOf(0xff.toByte(),0xd8.toByte(),0xff.toByte(),0xd9.toByte())
        backend.latest=CompleteFrame(1,jpeg,JpegSize(1280,720),System.nanoTime(),0.0)
        LocalHttpServer("",backend,0).use { server ->
            Socket("127.0.0.1",server.port).use { s ->
                s.soTimeout=1500
                s.getOutputStream().write("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n\r\n".toByteArray())
                val expected="\r\n--frame\r\n".toByteArray()
                val bytes=java.io.ByteArrayOutputStream()
                val input=s.getInputStream()
                while(true) {
                    val b=input.read(); assertTrue(b>=0); bytes.write(b)
                    val data=bytes.toByteArray()
                    if(data.size>200 && data.takeLast(expected.size).toByteArray().contentEquals(expected)) break
                }
                val data=bytes.toByteArray()
                assertTrue(data.takeLast(jpeg.size+expected.size).toByteArray().contentEquals(jpeg+expected))
            }
        }
    }
}
