package com.efinity.ti60

import android.content.Context
import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.net.*
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.SystemClock
import org.json.JSONObject
import java.net.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class Engine(private val context: Context) {
    @Volatile var latest: CompleteFrame?=null
    @Volatile var running=false
    @Volatile var message="尚未开始"
    @Volatile var board="192.168.0.2"
    @Volatile var port=5001
    @Volatile var simulation=false
    @Volatile var bufferSize=0
    @Volatile var wifi: Network?=null
    @Volatile var localIp="Wi-Fi 未连接"
    @Volatile var boardConfigured=false
    @Volatile private var autoConnect=false
    @Volatile private var lastSsid=""
    @Volatile private var lastPass=""
    @Volatile private var joinedSsid=""
    @Volatile private var connectThread: Thread?=null
    @Volatile private var specifierCallback: ConnectivityManager.NetworkCallback?=null
    @Volatile private var connectGeneration=0
    @Volatile private var reconnectScheduled=false
    @Volatile private var reconnectNeeded=false
    @Volatile private var pauseGeneration=0
    @Volatile private var wifiLock: WifiManager.WifiLock?=null
    @Volatile private var workerStartedNs=0L
    @Volatile private var lastVideoRestartNs=0L
    @Volatile private var socket: DatagramSocket?=null
    @Volatile private var control: DatagramSocket?=null
    @Volatile private var receiver: Thread?=null
    @Volatile private var poller: Thread?=null
    @Volatile private var assembler=JpegAssembler()
    @Volatile private var controlSeen=0L
    @Volatile private var agentMode="deepseek"
    @Volatile private var agentModel="deepseek-flash"
    @Volatile private var agentKey=""
    @Volatile private var agentSendImage=true
    @Volatile private var agentExecution=JSONObject().put("state","idle")
    @Volatile private var agentAutoActive=false
    @Volatile private var agentCancel=false
    private val commandGate=LiveAgent.CommandGate()
    private val agentWorker=Executors.newSingleThreadExecutor { r -> Thread(r,"ti60-agent").apply { isDaemon=true } }
    private val controlIo=Any()
    private var controlSeq=0
    private var desired=false
    private var resumed=true
    private var timeout=100L
    private val cm=context.getSystemService(ConnectivityManager::class.java)
    private val agentSettings=AgentSettings(context)
    val regs=ConcurrentHashMap<Int,JSONObject>()
    val packets=AtomicLong(); val bytes=AtomicLong(); val httpFrames=AtomicLong(); val clients=AtomicLong()
    val decodeErrors=AtomicLong()
    private var sampleNs=System.nanoTime(); private var sampleComplete=0L; private var samplePackets=0L
    private var sampleBytes=0L; private var sampleHttp=0L
    @Volatile private var agentConversation=AgentConversation()
    @Volatile private var lastAgentActionToken=0L
    @Volatile private var lastAgentAction=""
    @Volatile private var agentPermissionLatch:CountDownLatch?=null
    @Volatile private var agentPermissionGranted=false
    private var fps=0.0; private var pps=0.0; private var mbps=0.0; private var httpFps=0.0
    private val callback=object: ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { update(network) }
        override fun onLinkPropertiesChanged(network: Network, props: LinkProperties) { update(network) }
        override fun onLost(network: Network) { synchronized(this@Engine) {
            if(wifi==network) {
                Diagnostics.log("wifi lost (generic)")
                connectGeneration++; reconnectNeeded=true; wifi=null; joinedSsid=""; localIp="Wi-Fi 已断开"; boardConfigured=false; desired=false
                stopWorkers(); message="Wi-Fi 已断开，等待恢复"; scheduleReconnect()
            }
        } }
        private fun update(network: Network) { synchronized(this@Engine) {
            val caps=cm.getNetworkCapabilities(network)
            if(caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)!=true) return
            val ssid=(caps.transportInfo as? WifiInfo)?.ssid?.trim('"')
            val expected=joinedSsid.ifEmpty { lastSsid }
            // Never let the campus/other Wi-Fi callback steal the socket from VONETS.
            if(wifi!=null && wifi!=network) return
            if(wifi==null && (expected.isEmpty() || ssid!=expected)) return
            wifi=network
            localIp=cm.getLinkProperties(network)?.linkAddresses?.map { it.address }?.filterIsInstance<Inet4Address>()?.firstOrNull()?.hostAddress ?: "等待 IPv4"
            if(desired && resumed && !simulation && !running) startWorkers()
        } }
    }
    init {
        try {
            agentKey=agentSettings.readKey(); agentModel=agentSettings.model(); agentSendImage=agentSettings.sendImage()
            agentMode="deepseek"
            agentConversation=agentSettings.readConversation()
            agentConversation.repairDanglingToolCalls()
            agentSettings.saveConversation(agentConversation)
            val savedWifi=agentSettings.readWifi(); lastSsid=savedWifi.first; lastPass=savedWifi.second
            autoConnect=lastSsid=="VONETS_5G_804C"
        } catch(_:Exception) { Diagnostics.log("agent settings could not be restored") }
        cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),callback)
    }
    @Synchronized fun session(j: JSONObject) {
        val action=j.optString("action","start")
        if(action=="stop") {
            autoConnect=false; reconnectNeeded=false; Diagnostics.log("session stop")
            if(!commandGate.tryAcquire()) throw IllegalStateException("控制命令执行中，无法停止本地会话")
            try { desired=false; stopWorkers(); message="本地接收已停止（不改变板端出流）" }
            finally { commandGate.release() }
            return
        }
        require(action=="start")
        val ip=j.optString("board",board)
        require(ip.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")) && ip.split('.').all { it.toInt() in 0..255 }) { "请输入 IPv4 地址" }
        val newPort=j.optInt("port",5001); require(newPort in 1024..65535 && newPort!=5000) { "端口范围 1024..65535，不能占用控制端口 5000" }
        val newTimeout=j.optLong("timeout_ms",100); require(newTimeout in 20..500)
        if(!commandGate.tryAcquire()) throw IllegalStateException("控制正在执行，请完成或停止当前命令后再切换源")
        try {
            stopWorkers(); board=ip; port=newPort; timeout=newTimeout; simulation=j.optBoolean("simulation",false)
            desired=true; Diagnostics.log("session start board=$board port=$port simulation=$simulation")
            latest=null; assembler=JpegAssembler(timeout); packets.set(0); bytes.set(0); httpFrames.set(0); decodeErrors.set(0)
            regs.clear(); controlSeen=0L; sampleNs=System.nanoTime(); sampleComplete=0; samplePackets=0; sampleBytes=0; sampleHttp=0
            fps=0.0; pps=0.0; mbps=0.0; httpFps=0.0
            if(resumed) startWorkers()
        } finally { commandGate.release() }
    }
    /** One-tap: join VONETS, point the board at this phone, then start receiving. */
    fun connectBoard(ssid: String, passphrase: String) {
        val cleanSsid=ssid.trim()
        require(cleanSsid.isNotEmpty() && cleanSsid.length<=32) { "SSID 无效" }
        require(passphrase.isEmpty() || passphrase.length in 8..63) { "Wi-Fi 密码需 8–63 位" }
        rememberWifiProfile(cleanSsid,passphrase); autoConnect=true
        Diagnostics.log("connectBoard ssid=$cleanSsid")
        if(connectThread?.isAlive==true) { message="已有连接任务在运行"; return }
        val gen=++connectGeneration
        connectThread=thread(name="ti60-connect") { connectBoardBlocking(cleanSsid,passphrase,gen) }
    }

    fun rememberWifiProfile(ssid:String,passphrase:String) {
        val clean=ssid.trim()
        if(clean.isEmpty() || clean.length>32 || (passphrase.isNotEmpty() && passphrase.length !in 8..63)) return
        lastSsid=clean; lastPass=passphrase
        try { agentSettings.saveWifi(clean,passphrase) }
        catch(e:Exception) { Diagnostics.log("wifi credentials could not be persisted: ${e.message}") }
    }

    private fun connectBoardBlocking(ssid:String, pass:String, gen:Int) {
        try {
            if(gen!=connectGeneration) return
            val freshVideo=latest?.let { (System.nanoTime()-it.completedNs)/1_000_000<=2000 }==true
            if(wifi!=null && joinedSsid==ssid && running && freshVideo) {
                message="已连接 $localIp"
                Diagnostics.log("connect: already connected, reuse")
                return
            }
            Diagnostics.log("connect begin")
            port=5001
            autoConnect=true; desired=false; boardConfigured=false; stopWorkers()
            message="正在连接 VONETS Wi-Fi…"
            var network=existingVonetsNetwork(ssid)
            if(network==null && wifi!=null && joinedSsid==ssid) network=wifi
            Diagnostics.log(if(network==null) "connect: existing VONETS not found" else "connect: existing VONETS found")
            if(network==null) network=requestVonetsNetwork(ssid,pass,gen)
            if(gen!=connectGeneration) return
            if(network==null) { Diagnostics.log("connect: wifi unavailable"); message="Wi-Fi 连接失败或已取消；请确认 SSID/密码后重试"; return }
            wifi=network; joinedSsid=ssid; reconnectNeeded=false
            var ip:Inet4Address?=null
            val ipDeadline=SystemClock.elapsedRealtime()+10_000
            while(SystemClock.elapsedRealtime()<ipDeadline && gen==connectGeneration) {
                ip=cm.getLinkProperties(network)?.linkAddresses?.map { it.address }?.filterIsInstance<Inet4Address>()?.firstOrNull()
                if(ip!=null) break
                Thread.sleep(150)
            }
            if(ip==null) { message="Wi-Fi 已连接但未拿到 IPv4；检查 VONETS DHCP"; return }
            localIp=ip.hostAddress ?: "IPv4"
            Diagnostics.log("connect: wifi ip=$localIp")
            message="Wi-Fi $localIp，配置板端目的 IP…"
            Diagnostics.log("connect: dest config begin")
            val configured=configureBoardDestination(network,ip)
            if(!configured) {
                Diagnostics.log("connect: dest config not confirmed; continue for video")
                message="目的 IP 未确认，继续尝试接收…"
            } else {
                boardConfigured=true; Diagnostics.log("connect: dest config ok")
                message="板端目的 IP 已设为 $localIp，启动接收…"
            }
            if(gen!=connectGeneration) return
            val start=JSONObject().put("action","start").put("board",board).put("port",port)
                .put("timeout_ms",timeout).put("simulation",false)
            session(start)
            Diagnostics.log("connect: session started")
            val videoDeadline=SystemClock.elapsedRealtime()+8000
            while(SystemClock.elapsedRealtime()<videoDeadline && latest==null && gen==connectGeneration) Thread.sleep(120)
            val gotVideo=latest!=null
            if(gotVideo) boardConfigured=true
            message=if(gotVideo) "视频已连接 $localIp"
                else if(configured) "目的 IP 已配置，但 8 秒内未收到视频"
                else "未确认目的 IP，8 秒内未收到视频；检查板子/HDMI 输入"
            Diagnostics.log("connect: " + if(gotVideo) "video ok" else "no video after 8s")
        } catch(e:Exception) {
            boardConfigured=false
            Diagnostics.log("connect failed: ${e.message ?: e.javaClass.simpleName}")
            message="连接失败：${e.message ?: e.javaClass.simpleName}"
        } finally {
            if(reconnectNeeded && wifi==null) scheduleReconnect()
        }
    }

    private fun existingVonetsNetwork(ssid:String):Network? {
        return try {
            val wm=context.getSystemService(WifiManager::class.java) ?: return null
            val current=wm.connectionInfo?.ssid?.trim('"')
            val wifiNetworks=cm.allNetworks.filter {
                cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)==true
            }
            Diagnostics.log("wifi existing: current=$current expected=$ssid count=${wifiNetworks.size}")
            val bySsid=wifiNetworks.firstOrNull { n ->
                val c=cm.getNetworkCapabilities(n) ?: return@firstOrNull false
                val transportSsid=(c.transportInfo as? WifiInfo)?.ssid?.trim('"')
                // System-managed Wi-Fi often keeps INTERNET even when the AP has no uplink.
                transportSsid==ssid || (transportSsid==null && !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
            }
            if(bySsid!=null) return bySsid
            // SSID reads can be "<unknown ssid>" without location access. The board
            // subnet is a stronger signal: if any Wi-Fi already has 192.168.0.x, use it.
            val bySubnet=wifiNetworks.firstOrNull { n ->
                cm.getLinkProperties(n)?.linkAddresses?.any {
                    val a=it.address
                    a is Inet4Address && (a.address[0].toInt() and 255)==192 &&
                        (a.address[1].toInt() and 255)==168 && ((a.address[2].toInt() and 255)==0 || (a.address[2].toInt() and 255)==254)
                }==true
            }
            if(bySubnet!=null) Diagnostics.log("wifi existing: found by board subnet")
            bySubnet
        } catch(e:Exception) {
            Diagnostics.log("wifi existing failed: ${e.message}")
            null
        }
    }

    private fun requestVonetsNetwork(ssid:String, pass:String, gen:Int):Network? {
        val builder=WifiNetworkSpecifier.Builder().setSsid(ssid)
        if(pass.isNotEmpty()) builder.setWpa2Passphrase(pass)
        val spec=builder.build()
        val request=NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .setNetworkSpecifier(spec).build()
        Diagnostics.log("wifi specifier request ssid=$ssid")
        val latch=CountDownLatch(1)
        val ref=AtomicReference<Network?>(null)
        val cb=object:ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network:Network) {
                Diagnostics.log("wifi specifier available")
                if(gen==connectGeneration) { ref.set(network); latch.countDown() }
            }
            override fun onUnavailable() { Diagnostics.log("wifi specifier unavailable"); latch.countDown() }
            override fun onLost(network:Network) { synchronized(this@Engine) {
                if(wifi==network) {
                    Diagnostics.log("wifi lost")
                    connectGeneration++; reconnectNeeded=true; wifi=null; joinedSsid=""; localIp="Wi-Fi 已断开"; boardConfigured=false; desired=false
                    stopWorkers(); message="VONETS Wi-Fi 断开，等待恢复"; scheduleReconnect()
                }
            } }
        }
        try {
            specifierCallback?.let { try { cm.unregisterNetworkCallback(it) } catch(_:Exception) { } }
            specifierCallback=cb
            cm.requestNetwork(request,cb,30_000)
        } catch(e:Exception) { Diagnostics.log("wifi request failed: ${e.message}"); message="Wi-Fi 请求失败：${e.message}"; return null }
        if(!latch.await(35,TimeUnit.SECONDS)) { Diagnostics.log("wifi request timeout"); message="Wi-Fi 连接超时"; return null }
        val n=ref.get()
        if(n==null) { Diagnostics.log("wifi request cancelled/denied"); message="Wi-Fi 连接被取消或密码错误" }
        return n
    }

    @Synchronized private fun scheduleReconnect() {
        if(!autoConnect || !resumed || reconnectScheduled) return
        reconnectScheduled=true
        thread(name="ti60-reconnect") {
            try {
                Thread.sleep(1500)
                val wm=context.getSystemService(WifiManager::class.java)
                while(autoConnect && resumed && reconnectNeeded && wm?.isWifiEnabled==false) Thread.sleep(1000)
            } catch(_:InterruptedException) { Thread.currentThread().interrupt(); return@thread }
            try { connectThread?.join(40_000) } catch(_:InterruptedException) { Thread.currentThread().interrupt(); return@thread }
            synchronized(this@Engine) { reconnectScheduled=false }
            Diagnostics.log("reconnect attempt")
            if(autoConnect && resumed && wifi==null && connectThread?.isAlive!=true) connectBoard(lastSsid,lastPass)
        }
    }

    private fun configureBoardDestination(network:Network, ip:Inet4Address):Boolean {
        var s:DatagramSocket?=null
        try {
            s=DatagramSocket(null)
            s.reuseAddress=true
            network.bindSocket(s)
            s.bind(InetSocketAddress(5000))
            s.soTimeout=120
            val target=InetAddress.getByName(board)
            val ipValue=ipv4ToLong(ip)
            Diagnostics.log("dest config ip=$ip value=0x%08X".format(ipValue))
            repeat(3) {
                sendControl(s,target,0x0014,ipValue)
                sendControl(s,target,0x0018,5000)
                Thread.sleep(60)
            }
            Diagnostics.log("dest config writes sent")
            val deadline=SystemClock.elapsedRealtime()+4000
            while(SystemClock.elapsedRealtime()<deadline) {
                val seq=(++controlSeq) and 0xffff
                val req=ControlProtocol.read(seq,0x0000)
                s.send(DatagramPacket(req,req.size,target,5000))
                val readDeadline=SystemClock.elapsedRealtime()+220
                val data=ByteArray(64); val packet=DatagramPacket(data,data.size)
                while(SystemClock.elapsedRealtime()<readDeadline) {
                    s.soTimeout=maxOf(1,(readDeadline-SystemClock.elapsedRealtime()).toInt())
                    try {
                        packet.length=data.size; s.receive(packet)
                        if(packet.address!=target || packet.port!=5000) continue
                        val reply=ControlProtocol.reply(data,packet.length,seq,0x0000)
                        if(reply?.op==2 && reply.value==0x4e423031L) { Diagnostics.log("dest config NB01 ack"); return true }
                    } catch(_:SocketTimeoutException) { break }
                }
                Thread.sleep(80)
            }
            Diagnostics.log("dest config no NB01 ack")
            return false
        } catch(e:Exception) {
            Diagnostics.log("dest config failed: ${e.message ?: e.javaClass.simpleName}")
            message="板端配置失败：${e.message ?: e.javaClass.simpleName}"
            return false
        } finally { try { s?.close() } catch(_:Exception) { } }
    }

    private fun sendControl(s:DatagramSocket, target:InetAddress, reg:Int, value:Long) {
        val seq=(++controlSeq) and 0xffff
        val req=ControlProtocol.write(seq,reg,value)
        s.send(DatagramPacket(req,req.size,target,5000))
    }

    private fun ipv4ToLong(address:Inet4Address):Long {
        val b=address.address
        return ((b[0].toLong() and 0xff) shl 24) or ((b[1].toLong() and 0xff) shl 16) or
            ((b[2].toLong() and 0xff) shl 8) or (b[3].toLong() and 0xff)
    }

    private fun acquireWifiLock() {
        if(simulation || wifiLock?.isHeld==true) return
        try {
            wifiLock=context.getSystemService(WifiManager::class.java)
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF,"ti60:receive")?.apply {
                    setReferenceCounted(false); acquire()
                }
        } catch(e:Exception) { Diagnostics.log("wifi lock failed: ${e.message}") }
    }
    private fun releaseWifiLock() {
        try { if(wifiLock?.isHeld==true) wifiLock?.release() } catch(_:Exception) { }
        wifiLock=null
    }
    private fun startWorkers() {
        var opened: DatagramSocket?=null
        if(running) return
        if(!simulation && wifi==null) { message="等待 Wi-Fi（无需 Internet）"; return }
        if(!simulation) acquireWifiLock()
        try {
            val s=DatagramSocket(null); opened=s
            s.receiveBufferSize=8*1024*1024; s.reuseAddress=false
            if(!simulation) wifi!!.bindSocket(s)
            s.bind(InetSocketAddress(if(simulation) InetAddress.getLoopbackAddress() else null,port))
            s.soTimeout=25; socket=s; bufferSize=s.receiveBufferSize
            running=true; workerStartedNs=System.nanoTime(); Diagnostics.log("workers: running port=$port bound=${s.localPort}"); message=if(simulation) "离线模拟源 · 非实板" else "等待视频…"
            receiver=thread(name="ti60-udp") {
                val buf=ByteArray(65536); val d=DatagramPacket(buf,buf.size)
                while(!s.isClosed) {
                    try {
                        d.length=buf.size; s.receive(d)
                        if(!simulation && d.address.hostAddress!=board) continue
                        packets.incrementAndGet(); bytes.addAndGet(d.length.toLong())
                        try { val f=assembler.accept(VideoPacket.parse(buf,d.length)); if(f!=null) { if(latest==null) Diagnostics.log("video: first complete frame"); latest=f } }
                        catch(e: IllegalArgumentException) { assembler.stats.invalid++; message=e.message ?: "非法包" }
                    } catch(e: SocketTimeoutException) { assembler.expire(System.nanoTime()) }
                    catch(e: Exception) { if(!s.isClosed) { message="UDP: ${e.message}"; break } }
                }
                s.close()
                if(socket===s) running=false
            }
            if(simulation) startSimulation(s) else startControl()
        } catch(e: Exception) { running=false; opened?.close(); socket?.close(); releaseWifiLock(); Diagnostics.log("workers failed: ${e.message}"); message="启动失败：${e.message}；请检查端口、Wi-Fi 与局域网权限" }
    }
    /** Restart only the video socket/assembler; keep the control socket and poller alive. */
    @Synchronized private fun restartVideoOnly() {
        if(simulation || wifi==null) return
        val old=socket
        socket=null
        try { old?.close() } catch(_:Exception) { }
        try { receiver?.join(750) } catch(_:InterruptedException) { Thread.currentThread().interrupt() }
        latest=null; assembler=JpegAssembler(timeout)
        try {
            val s=DatagramSocket(null)
            s.receiveBufferSize=8*1024*1024; s.reuseAddress=false
            wifi!!.bindSocket(s)
            s.bind(InetSocketAddress(port)); s.soTimeout=25
            socket=s; bufferSize=s.receiveBufferSize; workerStartedNs=System.nanoTime()
            receiver=thread(name="ti60-udp") {
                val buf=ByteArray(65536); val d=DatagramPacket(buf,buf.size)
                while(!s.isClosed) {
                    try {
                        d.length=buf.size; s.receive(d)
                        if(!simulation && d.address.hostAddress!=board) continue
                        packets.incrementAndGet(); bytes.addAndGet(d.length.toLong())
                        try { val f=assembler.accept(VideoPacket.parse(buf,d.length)); if(f!=null) { if(latest==null) Diagnostics.log("video: first complete frame"); latest=f } }
                        catch(e: IllegalArgumentException) { assembler.stats.invalid++; message=e.message ?: "非法包" }
                    } catch(e: SocketTimeoutException) { assembler.expire(System.nanoTime()) }
                    catch(e: Exception) { if(!s.isClosed) { message="UDP: ${e.message}"; break } }
                }
                s.close()
                if(socket===s) running=false
            }
            Diagnostics.log("video: receiver restarted")
        } catch(e:Exception) {
            Diagnostics.log("video restart failed: ${e.message}")
            message="视频接收重启失败：${e.message}"
        }
    }
    private var simThread: Thread?=null
    private fun startSimulation(receiverSocket: DatagramSocket) {
        simThread=thread(name="ti60-sim") {
            DatagramSocket().use { sender ->
                val parts=context.assets.list("demo")!!.filter { it.endsWith(".udp") }.sorted().map { context.assets.open("demo/$it").use { f->f.readBytes() } }
                var id=0L; var deadline=System.nanoTime()
                while(!receiverSocket.isClosed && !Thread.currentThread().isInterrupted) {
                    for(raw in parts) {
                        if(receiverSocket.isClosed || Thread.currentThread().isInterrupted) break
                        val p=raw.clone(); java.nio.ByteBuffer.wrap(p).putInt(4,id.toInt()).putInt(16,(System.nanoTime()/1000).toInt())
                        sender.send(DatagramPacket(p,p.size,InetAddress.getLoopbackAddress(),port))
                        deadline+=33_333_333L/parts.size
                        val wait=deadline-System.nanoTime(); if(wait>0) java.util.concurrent.locks.LockSupport.parkNanos(wait)
                    }
                    id=(id+1) and 0xffffffffL
                    if(System.nanoTime()-deadline>100_000_000) deadline=System.nanoTime()
                }
            }
        }
    }
    private fun startControl() {
        var opened: DatagramSocket?=null
        try {
            val s=DatagramSocket(null); opened=s; wifi!!.bindSocket(s); s.bind(InetSocketAddress(5000)); s.soTimeout=100; control=s; Diagnostics.log("control: bound 5000")
            val target=InetAddress.getByName(board)
            poller=thread(name="ti60-control") {
                val previous=HashMap<Int,Pair<Long,Long>>()
                val pollRegs=ControlProtocol.registers
                while(!s.isClosed) {
                    val cycle=SystemClock.elapsedRealtime()
                    for(reg in pollRegs) {
                        if(s.isClosed) break
                        val response=exchange(read=true,reg=reg,value=0,retries=0,timeoutMs=100)
                        var value=response?.takeIf { it.op==2 }?.value
                        var error=if(response?.op==3) "NACK" else "超时"
                        if(reg==0 && value!=null && value!=0x4e423031L) { error="ID 不匹配"; value=null }
                        if(value!=null) controlSeen=System.nanoTime()
                        val stamp=System.nanoTime(); val prior=previous[reg]
                        val counter=reg in listOf(0x20,0x24,0x28,0x3c,0x0138,0x013C)
                        val delta=if(value!=null && prior!=null && stamp-prior.second<5_000_000_000L && counter) ((value-prior.first) and 0xffffffffL).takeIf { it<0x80000000L } else null
                        if(value!=null) previous[reg]=value to stamp else previous.remove(reg)
                        regs[reg]=JSONObject().put("delta",delta ?: JSONObject.NULL).put("rate_per_s",delta?.let { it/((stamp-prior!!.second)/1e9) } ?: JSONObject.NULL)
                            .put("value",value ?: JSONObject.NULL).put("hex",value?.let { "0x%08X".format(it) } ?: JSONObject.NULL)
                            .put("error",if(value==null) error else JSONObject.NULL).put("updated_ms",System.currentTimeMillis())
                    }
                    val delay=1000-(SystemClock.elapsedRealtime()-cycle)
                    if(delay>0) try { Thread.sleep(delay) } catch(e:InterruptedException) { break }
                }
            }
        } catch(e: Exception) { opened?.close(); Diagnostics.log("control bind failed: ${e.message}"); message="控制端口 5000 失败：${e.message}；视频接收仍可用" }
    }
    private fun stopWorkers() {
        running=false; socket?.close(); control?.close(); simThread?.interrupt(); poller?.interrupt()
        listOf(receiver,poller,simThread).forEach { try { it?.join(750) } catch(e: InterruptedException) { Thread.currentThread().interrupt() } }
        socket=null; control=null; receiver=null; poller=null; simThread=null
        releaseWifiLock()
    }
    @Synchronized fun pause() {
        resumed=false
        val gen=++pauseGeneration
        message="离开 App，本地接收已暂停"
        // A system Wi-Fi/permission dialog briefly pauses the Activity; don't tear
        // down the sockets for that blip.
        thread(name="ti60-pause", isDaemon=true) {
            try { Thread.sleep(1500) } catch(_:InterruptedException) { }
            synchronized(this@Engine) { if(!resumed && gen==pauseGeneration) stopWorkers() }
        }
    }
    @Synchronized fun resume() {
        resumed=true; pauseGeneration++
        if(autoConnect && !boardConfigured) { if(lastSsid.isNotEmpty()) connectBoard(lastSsid,lastPass) }
        else if(desired && !running) startWorkers()
    }
    @Synchronized fun close() {
        Diagnostics.log("engine close"); autoConnect=false; desired=false; pauseGeneration++
        connectGeneration++; connectThread?.interrupt()
        specifierCallback?.let { try { cm.unregisterNetworkCallback(it) } catch(_:Exception) { } }; specifierCallback=null
        stopWorkers(); agentKey=""; agentWorker.shutdownNow(); cm.unregisterNetworkCallback(callback)
    }
    @Synchronized fun status(): JSONObject {
        if(desired && resumed && !running && (simulation || wifi!=null)) startWorkers()
        val now=System.nanoTime(); val a=assembler.stats; val elapsed=(now-sampleNs)/1e9
        if(elapsed>=0.8) {
            fps=(a.complete-sampleComplete)/elapsed; pps=(packets.get()-samplePackets)/elapsed
            mbps=(bytes.get()-sampleBytes)*8/elapsed/1e6; httpFps=(httpFrames.get()-sampleHttp)/elapsed
            sampleNs=now; sampleComplete=a.complete; samplePackets=packets.get(); sampleBytes=bytes.get(); sampleHttp=httpFrames.get()
        }
        val f=latest; val age=f?.let { (now-it.completedNs)/1e6 }
        val noVideoMs=f?.let { (now-it.completedNs)/1e6 } ?: if(workerStartedNs==0L) 0.0 else (now-workerStartedNs)/1e6
        val online=controlSeen!=0L && now-controlSeen<8_000_000_000L
        val state=when { !running->"已停止 / 等待网络"; age!=null && age<=1000->if(simulation) "模拟源接收中" else "视频接收中"; f!=null->"画面已停滞"; online->"控制在线但视频未到"; else->"控制也不在线，视频未到" }
        return JSONObject().put("state",state).put("message",message).put("running",running).put("simulation",simulation)
            .put("board",board).put("port",port).put("local_ip",localIp).put("wifi_ssid",joinedSsid)
            .put("wifi_active",wifi!=null).put("saved_reconnect_available",lastSsid.isNotBlank()).put("control_online",online)
            .put("internet_network",internetState()).put("agent",agentStatus())
            .put("firmware","DDR MJPEG / 固定 1280×720 / 30fps / FPGA 编码；参数暂不可调")
            .put("routing_warning",if(boardConfigured) "" else "当前固件目的端固定，尚未配置为此手机；需 FPGA 目的 IP/ARP 配套修改")
            .put("board_configured",boardConfigured)
            .put("has_frame",f!=null).put("age_ms",age ?: JSONObject.NULL).put("frame_id",f?.id ?: JSONObject.NULL)
            .put("width",f?.size?.width ?: JSONObject.NULL).put("height",f?.size?.height ?: JSONObject.NULL)
            .put("updated_ms",f?.let { System.currentTimeMillis()-((now-it.completedNs)/1_000_000) } ?: JSONObject.NULL)
            .put("fps_complete",fps).put("fps_http",httpFps).put("fps_display",JSONObject.NULL)
            .put("http_fps_definition","所有 HTTP 客户端已写出帧总数 / 秒")
            .put("udp_pps",pps).put("udp_mbps",mbps).put("udp_packets",packets.get()).put("udp_bytes",bytes.get())
            .put("complete",a.complete).put("incomplete",a.incomplete).put("missing",a.missing).put("duplicate",a.duplicate)
            .put("reordered",a.reordered).put("invalid",a.invalid).put("stale",a.stale).put("restarts",a.restarts)
            .put("assembly_timeout_ms",timeout).put("assembly_timeout_drops",a.timeoutDrops).put("assembly_window_drops",a.windowDrops)
            .put("assembly_ms",f?.assemblyMs ?: JSONObject.NULL).put("rcvbuf_bytes",bufferSize)
            .put("http_clients",clients.get()).put("decode_errors",JSONObject.NULL).put("web_stream_errors",decodeErrors.get()).put("regs",registerJson())
    }
    fun registerJson(): JSONObject=JSONObject().apply { ControlProtocol.registers.forEach { put("0x%04X".format(it),regs[it] ?: JSONObject().put("value",JSONObject.NULL).put("error","未读取")) } }

    @Synchronized private fun linkState():JSONObject {
        val n=wifi
        val info=try { context.getSystemService(WifiManager::class.java)?.connectionInfo } catch(_:Exception) { null }
        val power=context.getSystemService(android.os.PowerManager::class.java)
        return JSONObject().put("network_handle",n?.networkHandle ?: 0L).put("local_ip",localIp)
            .put("resumed",resumed).put("desired",desired).put("running",running)
            .put("auto_connect",autoConnect).put("reconnect_needed",reconnectNeeded)
            .put("board_configured",boardConfigured).put("wifi_lock_held",wifiLock?.isHeld==true)
            .put("interactive",power?.isInteractive==true)
            .put("control_socket_closed",control?.isClosed ?: true).put("video_socket_closed",socket?.isClosed ?: true)
            .put("rssi",info?.rssi ?: -127).put("rx_link_mbps",info?.rxLinkSpeedMbps ?: 0)
            .put("tx_link_mbps",info?.txLinkSpeedMbps ?: 0).put("frequency",info?.frequency ?: 0)
    }

    /** Routes only this HTTPS request over an explicitly selected Internet network. */
    private fun internetConnection(url: URL): LiveAgent.ConnectionLease {
        val available=cm.allNetworks.firstOrNull { n ->
            val c=cm.getNetworkCapabilities(n)
            c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)==true &&
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }
        if(available!=null) return LiveAgent.ConnectionLease(available.openConnection(url) as HttpURLConnection)
        val latch=CountDownLatch(1); val chosen=java.util.concurrent.atomic.AtomicReference<Network?>(null)
        val request=NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
        val callback=object: ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network:Network,capabilities:NetworkCapabilities) {
                if(capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                    chosen.set(network); latch.countDown()
                }
            }
            override fun onUnavailable() { latch.countDown() }
        }
        var transferred=false
        try {
            cm.requestNetwork(request,callback,12_000)
            if(!latch.await(12,TimeUnit.SECONDS) || chosen.get()==null)
                throw LiveAgent.AgentFailure("没有可用 Internet：当前 Wi-Fi 无公网，且蜂窝数据不可用或未获系统接入；未发送设备命令")
            val conn=chosen.get()!!.openConnection(url) as HttpURLConnection
            transferred=true
            return LiveAgent.ConnectionLease(conn) { try { cm.unregisterNetworkCallback(callback) } catch(_: Exception) { } }
        } catch(e: LiveAgent.AgentFailure) { throw e }
        catch(e: Exception) { throw LiveAgent.AgentFailure("无法接入 Internet 网络（未开启移动数据或系统拒绝）：${e.message ?: "网络不可用"}；未发送设备命令") }
        finally { if(!transferred) try { cm.unregisterNetworkCallback(callback) } catch(_: Exception) { } }
    }

    /** Authenticated local HTTP API backend for manual controls and Agent. */
    fun api(path:String, body:String):String {
        val input=JSONObject(body)
        return when(path) {
            "/api/agent/status" -> agentStatus().toString()
            "/api/agent/history" -> agentHistory().toString()
            "/api/agent/clear" -> clearAgentConversation().toString()
            "/api/agent/config" -> {
                val mode="deepseek"; val model=input.optString("model",agentModel); val key=input.optString("key","")
                val sendImage=if(input.has("send_image")) input.optBoolean("send_image") else agentSendImage
                require(mode in listOf("offline","deepseek") && model.isNotBlank() && model.length<=80 && key.length<=500) { "mode、model 或 Key 格式无效" }
                if(mode=="deepseek" && key.isBlank() && agentKey.isBlank()) throw IllegalArgumentException("DeepSeek 模式需要 API Key")
                val newKey=key.trim().takeIf { it.isNotEmpty() }
                try { agentSettings.save(mode,model.trim(),sendImage,newKey) }
                catch(_:Exception) { throw IllegalStateException("无法加密保存 Agent 设置，请重试") }
                agentMode=mode; agentModel=model.trim(); agentSendImage=sendImage; if(newKey!=null) agentKey=newKey
                JSONObject().put("ok",true).put("mode",agentMode).put("model",agentModel)
                    .put("send_image",agentSendImage).put("key_set",agentKey.isNotEmpty()).toString()
            }
            "/api/agent/plan" -> {
                val text=LiveAgent.validateText(input.optString("text"))
                val plan=if(agentMode=="offline") LiveAgent.offlinePlan(text) else
                    LiveAgent.deepSeekPlan(text,agentKey,agentModel,opener=::internetConnection)
                JSONObject().put("ok",true).put("engine",agentMode).put("plan",plan.json()).put("preview",plan.preview()).put("hardware_online",isControlOnline()).toString()
            }
            "/api/agent/scene_plan" -> {
                val frame=latest ?: throw IllegalStateException("暂无完整画面帧；请先开始接收")
                val text=input.optString("text","").ifBlank { "根据当前画面分析，推荐 1-2 个适合的画面风格组合并说明理由，然后生成对应的动作计划。" }
                val stats=sceneStats(frame.jpeg)
                val summary=SceneStats.summary(stats)
                val plan=if(agentMode=="offline") LiveAgent.recommendFromScene(stats) else
                    LiveAgent.deepSeekPlan(text,agentKey,agentModel,
                        image=if(agentSendImage) frame.jpeg else null, sceneSummary=summary, opener=::internetConnection)
                JSONObject().put("ok",true).put("engine",agentMode).put("scene",summary)
                    .put("stats",SceneStats.json(stats)).put("image_sent",agentMode=="deepseek" && agentSendImage)
                    .put("plan",plan.json()).put("preview",plan.preview()).put("hardware_online",isControlOnline()).toString()
            }
            "/api/agent/execute" -> {
                val plan=LiveAgent.validatePlan(input.optJSONObject("plan") ?: throw IllegalArgumentException("计划 JSON 无效；未执行"))
                startAgent(plan)
            }
            "/api/agent/run" -> startAutonomous(LiveAgent.validateText(input.optString("text")))
            "/api/agent/cancel" -> {
                if(agentAutoActive) { agentCancel=true; LiveAgent.cancelCurrentAgentRequest() }
                JSONObject().put("ok",true).put("requested",agentAutoActive).toString()
            }
            "/api/link-state" -> linkState().toString()
            "/api/link-probe" -> linkProbe(input.optBoolean("pause_stream",false)).toString()
            "/api/control/action" -> {
                val action=input.optString("action")
                val bodyPlan=LiveAgent.validatePlan(JSONObject().put("reply","manual").put("steps",org.json.JSONArray().put(JSONObject().put("action",action).put("count",1))))
                executePlan(bodyPlan)
            }
            "/api/control/set" -> setParameter(input.optString("field"), input.opt("value"))
            else -> throw IllegalArgumentException("未知 API")
        }
    }

    /** Debug-only, loopback/CSRF-protected, fixed destinations/registers.
     * Optional load probe temporarily stops video and always restores enable. */
    private fun linkProbe(pauseStream:Boolean=false):JSONObject {
        val network=wifi
        val result=JSONObject().put("ok",true).put("wifi_active",network!=null)
            .put("network_handle",network?.networkHandle ?: 0L).put("local_ip",localIp)
        val ap=JSONObject();result.put("ap",ap)
        val began=SystemClock.elapsedRealtime()
        try {
            require(network!=null) { "no selected Wi-Fi network" }
            network.socketFactory.createSocket().use { s ->
                s.connect(InetSocketAddress("192.168.0.1",80),2000);s.soTimeout=2000
                ap.put("tcp_ms",SystemClock.elapsedRealtime()-began)
                s.getOutputStream().write("HEAD / HTTP/1.0\r\nHost: 192.168.0.1\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                ap.put("http_status",s.getInputStream().bufferedReader(Charsets.US_ASCII).readLine()?.take(120))
            }
        } catch(e:Exception) { ap.put("error",e.javaClass.simpleName+": "+e.message) }
        ap.put("elapsed_ms",SystemClock.elapsedRealtime()-began)
        val reads=org.json.JSONArray();result.put("reads",reads)
        // Isolate wire reply time from waiting behind the normal control poller.
        synchronized(controlIo) {
            if(pauseStream) {
                require(network!=null&&wifi==network&&running&&control?.isClosed==false) { "active receive session required" }
                val load=JSONObject();result.put("load_probe",load)
                try {
                    // Current receive mode has stream enabled (not a saved setting).
                    val stop=org.json.JSONArray();load.put("stop_acks",stop)
                    repeat(3) { stop.put(exchange(false,0x000c,0,0,300)?.value ?: JSONObject.NULL) }
                    Thread.sleep(1000)
                    val t=SystemClock.elapsedRealtime()
                    try { network.socketFactory.createSocket().use { s ->
                        s.connect(InetSocketAddress("192.168.0.1",80),2000)
                        load.put("ap_tcp_ms_stopped",SystemClock.elapsedRealtime()-t)
                    } } catch(e:Exception) { load.put("ap_error_stopped",e.javaClass.simpleName+": "+e.message) }
                    for(reg in listOf(0,0x000c,0x0018,0x0020,0x0024,0x0028,0x0040,0x0044)) {
                        val t0=SystemClock.elapsedRealtime();val r=exchange(true,reg,0,0,500)
                        reads.put(JSONObject().put("reg",reg).put("timeout_ms",500).put("elapsed_ms",SystemClock.elapsedRealtime()-t0)
                            .put("op",r?.op ?: JSONObject.NULL).put("value",r?.value ?: JSONObject.NULL))
                    }
                } finally {
                    val restore=org.json.JSONArray();load.put("restore_acks",restore)
                    repeat(3) { restore.put(exchange(false,0x000c,1,0,1000)?.value ?: JSONObject.NULL) }
                }
                Diagnostics.log("link load probe "+result.toString())
                return result
            }
            for(ms in listOf(100,500,1500)) {
                val t=SystemClock.elapsedRealtime();val r=exchange(true,0,0,0,ms)
                reads.put(JSONObject().put("reg",0).put("timeout_ms",ms).put("elapsed_ms",SystemClock.elapsedRealtime()-t)
                    .put("op",r?.op ?: JSONObject.NULL).put("value",r?.value ?: JSONObject.NULL))
            }
            for(reg in listOf(0x000c,0x0014,0x0018,0x0020,0x0024,0x0028,0x0040,0x0044)) {
                val t=SystemClock.elapsedRealtime();val r=exchange(true,reg,0,0,500)
                reads.put(JSONObject().put("reg",reg).put("timeout_ms",500).put("elapsed_ms",SystemClock.elapsedRealtime()-t)
                    .put("op",r?.op ?: JSONObject.NULL).put("value",r?.value ?: JSONObject.NULL))
            }
        }
        Diagnostics.log("link probe AP="+ap.toString()+" reads="+reads.toString())
        return result
    }

    fun agentStatus():JSONObject=JSONObject().put("mode",agentMode).put("model",agentModel)
        .put("send_image",agentSendImage)
        .put("luts",org.json.JSONArray().also { arr -> LiveAgent.lutCatalog.forEach { row -> arr.put(org.json.JSONArray(row)) } })
        .put("styles",org.json.JSONArray(LiveAgent.styleCatalog))
        .put("key_set",agentKey.isNotEmpty()).put("execution",JSONObject(agentExecution.toString()))
    fun agentHistory():JSONObject=synchronized(agentConversation) {
        JSONObject().put("messages",agentConversation.visibleMessages())
    }

    @Synchronized private fun clearAgentConversation():JSONObject {
        if(agentAutoActive) return JSONObject().put("ok",false).put("error","Agent 正在处理请求；完成或停止后再清空记忆")
        agentSettings.clearConversation()
        agentConversation=AgentConversation()
        return JSONObject().put("ok",true).put("message","对话记录和 Agent 上下文记忆已清空；Agent 设置与 API Key 保留")
    }

    /** 解码 JPEG 并降采样统计；失败时抛出可读错误（不伪造分析）。 */
    private fun sceneStats(jpeg: ByteArray): SceneStats.Stats {
        val bmp=android.graphics.BitmapFactory.decodeByteArray(jpeg,0,jpeg.size)
            ?: throw IllegalStateException("画面帧解码失败")
        val w=64; val h=maxOf(1,bmp.height*w/bmp.width)
        val pixels=IntArray(w*h)
        val scaled=android.graphics.Bitmap.createScaledBitmap(bmp,w,h,true)
        scaled.getPixels(pixels,0,w,0,0,w,h)
        if(scaled!==bmp) scaled.recycle(); bmp.recycle()
        return SceneStats.analyze(pixels,w,h)
    }

    private fun isControlOnline()=controlSeen!=0L && System.nanoTime()-controlSeen<8_000_000_000L

    /** Pi-style session loop: persist every assistant tool call/result and resume until final text. */
    @Synchronized private fun startAutonomous(text:String):String {
        if(agentAutoActive) throw IllegalStateException("Agent 正在处理上一条请求")
        agentCancel=false; agentAutoActive=true
        synchronized(agentConversation) {
            agentConversation.addUser(text)
            try { agentSettings.saveConversation(agentConversation) } catch(e:Exception) { Diagnostics.log("conversation save failed: ${e.message}") }
        }
        agentExecution=JSONObject().put("state","thinking").put("completed",org.json.JSONArray())
        try {
            agentWorker.execute {
                val completed=org.json.JSONArray(); var reply=""; var result="done"; var error=""
                try {
                    if(agentMode=="offline") {
                        val plan=LiveAgent.offlinePlan(text); reply=plan.reply
                        if(plan.steps.isNotEmpty()) {
                            val execution=JSONObject(executePlan(plan)); val done=execution.optJSONArray("completed") ?: org.json.JSONArray()
                            for(i in 0 until done.length()) completed.put(done.get(i))
                            if(!execution.optBoolean("ok",false)) { result="error"; error=execution.optString("err",execution.optString("state")) }
                        }
                    } else {
                        while(true) {
                            if(agentCancel) { result="cancelled"; break }
                            agentExecution=JSONObject().put("state","thinking").put("completed",completed)
                            val frame=latest?.takeIf { System.nanoTime()-it.completedNs<2_000_000_000L }
                            val turn=LiveAgent.deepSeekAgentTurn(agentConversation.apiMessages(),agentKey,agentModel,
                                image=if(agentSendImage) frame?.jpeg else null,opener=::internetConnection)
                            if(agentCancel) { result="cancelled"; break }
                            if(turn.calls.isEmpty()) {
                                reply=turn.text ?: "已结束。"
                                synchronized(agentConversation) {
                                    agentConversation.addAssistantFinal(reply)
                                    try { agentSettings.saveConversation(agentConversation) } catch(e:Exception) { Diagnostics.log("conversation save failed: ${e.message}") }
                                }
                                break
                            }
                            synchronized(agentConversation) {
                                agentConversation.addAssistant(turn.assistantMessage)
                                try { agentSettings.saveConversation(agentConversation) } catch(e:Exception) { Diagnostics.log("conversation save failed: ${e.message}") }
                            }
                            for((index,call) in turn.calls.withIndex()) {
                                if(agentCancel) {
                                    for(pending in turn.calls.drop(index)) {
                                        synchronized(agentConversation) { agentConversation.addToolResult(pending.id,"{\"ok\":false,\"state\":\"cancelled\",\"message\":\"用户停止了 Agent\"}") }
                                    }
                                    result="cancelled"; break
                                }
                                agentExecution=JSONObject().put("state","tool_running").put("tool",call.name).put("completed",completed)
                                val toolResult=try { executeAgentTool(call.name,call.arguments) }
                                catch(e:Exception) { JSONObject().put("ok",false).put("error",e.message ?: e.javaClass.simpleName) }
                                val done=toolResult.optJSONArray("completed")
                                if(done!=null) for(i in 0 until done.length()) completed.put(done.get(i))
                                synchronized(agentConversation) {
                                    agentConversation.addToolResult(call.id,toolResult.toString())
                                    try { agentSettings.saveConversation(agentConversation) } catch(e:Exception) { Diagnostics.log("conversation save failed: ${e.message}") }
                                }
                                agentExecution=JSONObject().put("state","tool_result").put("tool",call.name)
                                    .put("tool_result",toolResult).put("completed",completed)
                            }
                            if(result=="cancelled") break
                            // Tool results are fed back on the next iteration together with a fresh frame.
                        }
                    }
                    if(agentMode=="offline") synchronized(agentConversation) {
                        agentConversation.addAssistantFinal(reply)
                        try { agentSettings.saveConversation(agentConversation) } catch(e:Exception) { Diagnostics.log("conversation save failed: ${e.message}") }
                    }
                } catch(e:Exception) { result=if(agentCancel) "cancelled" else "error"; error=e.message ?: "执行失败" }
                finally {
                    val finalText=if(error.isNotBlank()) (reply.takeIf { it.isNotBlank() }?.plus("\n") ?: "")+error else reply
                    if(result!="done" && finalText.isNotBlank()) synchronized(agentConversation) {
                        agentConversation.addAssistantFinal(finalText)
                        try { agentSettings.saveConversation(agentConversation) } catch(_:Exception) { }
                    }
                    agentExecution=JSONObject().put("state",result).put("ok",result=="done")
                        .put("reply",reply).put("err",error).put("completed",completed)
                    agentAutoActive=false
                }
            }
        } catch(e:Exception) { agentAutoActive=false; throw e }
        return JSONObject().put("ok",true).put("state","thinking").toString()
    }
    private fun internetState():String {
        val n=cm.allNetworks.firstOrNull { net -> val c=cm.getNetworkCapabilities(net)
            c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)==true && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) }
            ?: return "无已验证公网；DeepSeek 计划不可用（可由系统允许时请求蜂窝接入）"
        val c=cm.getNetworkCapabilities(n)
        return when { c?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)==true -> "Wi-Fi 已连且有公网"; c?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)==true -> "蜂窝公网可用"; else -> "其他公网网络可用" }
    }

    private fun networkStatusJson():JSONObject {
        val rows=org.json.JSONArray()
        for(n in cm.allNetworks) {
            val c=cm.getNetworkCapabilities(n) ?: continue
            val lp=cm.getLinkProperties(n)
            val transports=org.json.JSONArray().apply {
                if(c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) put("wifi")
                if(c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) put("cellular")
                if(c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) put("ethernet")
                if(c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) put("vpn")
                if(c.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) put("bluetooth")
            }
            val ssid=(c.transportInfo as? WifiInfo)?.ssid?.trim('"')
            rows.put(JSONObject().put("transports",transports).put("ssid",ssid ?: JSONObject.NULL)
                .put("internet",c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
                .put("validated",c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                .put("metered",!c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                .put("addresses",org.json.JSONArray().also { a -> lp?.linkAddresses?.forEach { a.put(it.address.hostAddress) } })
                .put("dns",org.json.JSONArray().also { a -> lp?.dnsServers?.forEach { a.put(it.hostAddress) } }))
        }
        return JSONObject().put("current_wifi",joinedSsid.takeIf { it.isNotBlank() } ?: JSONObject.NULL)
            .put("wifi_ip",localIp).put("internet",internetState()).put("networks",rows)
            .put("saved_reconnect_available",lastSsid.isNotBlank()).put("nearby_wifi_permission",hasWifiPermission())
    }

    private fun hasWifiPermission():Boolean {
        val permission=if(android.os.Build.VERSION.SDK_INT>=33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        return context.checkSelfPermission(permission)==PackageManager.PERMISSION_GRANTED
    }

    private fun awaitWifiPermission():Boolean {
        if(hasWifiPermission()) return true
        val activity=context as? Activity ?: return false
        val latch=CountDownLatch(1)
        agentPermissionGranted=false; agentPermissionLatch=latch
        val permissions=if(android.os.Build.VERSION.SDK_INT>=33) arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        activity.runOnUiThread { if(!activity.isFinishing) activity.requestPermissions(permissions,18) else latch.countDown() }
        val completed=try { latch.await(60,TimeUnit.SECONDS) } catch(_:InterruptedException) { Thread.currentThread().interrupt(); false }
        agentPermissionLatch=null
        return completed && agentPermissionGranted && hasWifiPermission()
    }

    fun agentWifiPermissionResult(granted:Boolean) {
        agentPermissionGranted=granted
        agentPermissionLatch?.countDown()
    }

    private fun reconnectBoardForAgent():JSONObject {
        if(lastSsid.isBlank()) return JSONObject().put("ok",false).put("state","missing_wifi_profile")
            .put("message","App 尚无已保存的 VONETS 配置；请先在连接设置中连接一次")
        if(!awaitWifiPermission()) return JSONObject().put("ok",false).put("state","wifi_permission_missing")
            .put("message","Android 附近 Wi-Fi 权限未授予，系统权限窗口未获批准或超时")
        val existing=connectThread
        if(existing?.isAlive==true) {
            try { existing.join(45_000) } catch(_:InterruptedException) { Thread.currentThread().interrupt() }
        } else {
            connectBoard(lastSsid,lastPass)
            try { connectThread?.join(45_000) } catch(_:InterruptedException) { Thread.currentThread().interrupt() }
        }
        return JSONObject().put("ok",running && wifi!=null).put("state",if(running && wifi!=null) "connected" else "connect_incomplete")
            .put("message",message).put("status",status()).put("network",networkStatusJson())
    }

    private fun checkDeviceReceipt():JSONObject {
        if(lastAgentActionToken==0L) return JSONObject().put("ok",false).put("state","no_recent_agent_command")
            .put("message","没有可检查的 Agent 命令回执").put("control_online",isControlOnline())
        if(lastCommandState in setOf("stage_failed","bridge_unavailable","busy"))
            return JSONObject().put("ok",false).put("state","not_committed").put("token",lastAgentActionToken)
                .put("action",lastAgentAction).put("retry_safe",true)
                .put("message","该命令未进入 FPGA 已提交状态；可重试，也可先检查连接")
        val state=waitA(lastAgentActionToken,2200)
        return JSONObject().put("ok",state=="a_accepted").put("state",state).put("token",lastAgentActionToken)
            .put("action",lastAgentAction).put("control_online",isControlOnline())
            .put("retry_safe",state in setOf("a_rejected","uart_error","cpu_fault"))
            .put("message",if(state=="a_accepted") "FPGA 已确认接收该命令" else "FPGA 尚未给出成功回执；请结合画面和链路状态决定是否重试")
    }

    /** Dispatches every native app function as a model-callable tool. */
    private fun executeAgentTool(name:String,args:JSONObject):JSONObject = when(name) {
        "inspect_app" -> JSONObject().put("ok",true).put("status",status()).put("network",networkStatusJson())
            .put("last_command",if(lastAgentActionToken==0L) JSONObject.NULL else JSONObject().put("action",lastAgentAction).put("token",lastAgentActionToken))
        "network_status" -> JSONObject().put("ok",true).put("network",networkStatusJson()).put("message",message)
        "observe_screen" -> {
            val frame=latest
            if(frame==null) JSONObject().put("ok",false).put("state","no_frame").put("message","尚无完整画面；检查接收会话或重新连接")
            else {
                val age=((System.nanoTime()-frame.completedNs)/1_000_000).coerceAtLeast(0)
                val stats=sceneStats(frame.jpeg)
                JSONObject().put("ok",true).put("frame_id",frame.id).put("age_ms",age)
                    .put("width",frame.size.width).put("height",frame.size.height)
                    .put("scene",SceneStats.summary(stats)).put("stats",SceneStats.json(stats))
                    .put("screen_image","最新 JPEG 将随下一次模型调用发送")
            }
        }
        "reconnect_board" -> reconnectBoardForAgent()
        "set_receive_session" -> {
            if(!args.has("action") || args.optString("action") !in setOf("start","stop"))
                JSONObject().put("ok",false).put("error","action 必须为 start 或 stop")
            else {
                session(args)
                JSONObject().put("ok",running || args.optString("action")=="stop").put("state",if(running) "running" else "stopped")
                    .put("message",message).put("status",status())
            }
        }
        "control_action" -> {
            val action=args.optString("action")
            val count=if(args.has("count")) args.opt("count") as? Int else 1
            if(action !in LiveAgent.allowed && action !in LiveAgent.videoModes || count==null || count<1)
                JSONObject().put("ok",false).put("error","设备动作名或 count 参数无效")
            else {
                val plan=LiveAgent.Plan("Agent tool",listOf(LiveAgent.Step(action,count)))
                val outcome=JSONObject(executePlan(plan))
                if(outcome.optBoolean("ok")) outcome.put("message","FPGA 已回执；画面效果可用 observe_screen 核验")
                else outcome.put("retry_guidance","先调用 check_device_receipt、inspect_app 或 observe_screen 读取实际状态；确认目标未达到后可重新调用 control_action。")
            }
        }
        "set_parameter" -> JSONObject(setParameter(args.optString("field"),args.opt("value")))
        "set_ui_visibility" -> {
            val visible=args.opt("visible") as? Boolean
            if(visible==null) JSONObject().put("ok",false).put("error","visible 必须为布尔值")
            else {
                val action=if(visible) "ui_restore" else "ui_hide_all"
                val outcome=JSONObject(executePlan(LiveAgent.Plan("Agent UI visibility",listOf(LiveAgent.Step(action,1)))))
                if(outcome.optBoolean("ok")) outcome.put("visible",visible)
                    .put("message",if(visible) "已发送恢复 FPGA 画面 UI 命令；可用 observe_screen 核验" else "已发送完全隐藏 FPGA 画面 UI 命令；远程控制仍可继续")
                else outcome.put("retry_guidance","先调用 check_device_receipt、inspect_app 或 observe_screen 检查实际状态，再决定是否重试")
            }
        }
        "check_device_receipt" -> checkDeviceReceipt()
        "read_diagnostics" -> JSONObject().put("ok",true).put("diagnostics",Diagnostics.dump().takeLast(16_000))
        else -> JSONObject().put("ok",false).put("error","未知 Agent 工具")
    }

    private fun startAgent(plan:LiveAgent.Plan):String {
        if(simulation) throw IllegalStateException("离线模拟源禁止发送任何实板控制命令")
        if(!running || control==null || wifi==null) throw IllegalStateException("实板控制链路未启动")
        if(!commandGate.tryAcquire()) throw IllegalStateException("Agent/手动控制正在执行，请稍后再试")
        if(simulation) { commandGate.release(); throw IllegalStateException("离线模拟源禁止发送任何实板控制命令") }
        agentExecution=JSONObject().put("state","queued").put("completed",org.json.JSONArray())
        try {
            agentWorker.execute {
                try { agentExecution=JSONObject(executePlanLocked(plan)) }
                catch(e:Exception) { agentExecution=JSONObject().put("ok",false).put("state","error").put("err",e.message ?: "Agent 执行失败").put("completed",org.json.JSONArray()) }
                finally { commandGate.release() }
            }
        } catch(e:Exception) { commandGate.release(); throw e }
        return JSONObject().put("ok",true).put("state","queued").toString()
    }

    private fun executePlan(plan:LiveAgent.Plan):String {
        if(simulation) throw IllegalStateException("离线模拟源禁止发送任何实板控制命令")
        if(!running || control==null || wifi==null) throw IllegalStateException("实板控制链路未启动")
        if(!commandGate.tryAcquire()) throw IllegalStateException("Agent/手动控制正在执行，请稍后再试")
        try { if(simulation) throw IllegalStateException("离线模拟源禁止发送任何实板控制命令"); return executePlanLocked(plan) } finally { commandGate.release() }
    }

    private fun setParameter(field:String, raw:Any?):String {
        val payload=DeviceParameters.payload(field,raw)
        val value=(payload[1].toInt() and 255)
        if(simulation || !running || control==null || wifi==null) throw IllegalStateException("实板控制链路未启动")
        if(!commandGate.tryAcquire()) throw IllegalStateException("控制正在执行，请稍后再试")
        try {
            lastAgentAction="set:$field=$value"
            lastAgentActionToken=0L
            val token=queueACommand(0x27,payload)
                ?: return JSONObject().put("ok",false).put("state",lastCommandState).toString()
            lastAgentActionToken=token
            val state=waitA(token,3500)
            return JSONObject().put("ok",state=="a_accepted").put("state",state).put("token",token).put("field",field).put("value",value).toString()
        } finally { commandGate.release() }
    }

    /** Caller holds commandGate for the whole transaction. */
    private fun executePlanLocked(plan:LiveAgent.Plan):String {
        if(plan.steps.isEmpty()) return JSONObject().put("ok",true).put("state","no_commands").put("completed",org.json.JSONArray()).put("note","空计划，没有发送设备命令。").toString()
        val completed=org.json.JSONArray()
        agentExecution=JSONObject().put("state","running").put("completed",completed)
        for(step in plan.steps) repeat(step.count) {
            val action=step.action
            if(agentAutoActive && agentCancel) return JSONObject().put("ok",false).put("state","cancelled").put("completed",completed).put("err","已停止后续动作") .toString()
            Diagnostics.log("control action=$action")
            lastAgentAction=action
            lastAgentActionToken=0L
            val (type,payload)=if(action in LiveAgent.videoModes) 0x10 to byteArrayOf(LiveAgent.videoModes.getValue(action).toByte())
                else 0x25 to byteArrayOf(LiveAgent.actionIds.getValue(action).toByte())
            val token=queueACommand(type,payload)
            if(token==null) return JSONObject().put("ok",false).put("state",lastCommandState).put("completed",completed).put("action",action)
                .put("token",lastAgentActionToken).put("err",if(lastCommandState=="commit_unknown") "提交结果未知；请检查 token/状态和当前画面后决定是否重试" else "板2未确认提交；请检查设备状态后决定是否重试").toString()
            lastAgentActionToken=token
            agentExecution=JSONObject().put("state","b_queued").put("token",token).put("action",action).put("completed",completed)
            val state=waitA(stateToken=token,timeoutMs=3500)
            if(state!="a_accepted") return JSONObject().put("ok",false).put("state",state).put("token",token).put("completed",completed).put("action",action)
                .put("err","A 暂未确认接收；请通过 check_device_receipt/画面判断后继续恢复").toString()
            completed.put(JSONObject().put("action",action).put("token",token).put("state",state))
            agentExecution=JSONObject().put("state","step_accepted").put("token",token).put("action",action).put("completed",completed)
        }
        return JSONObject().put("ok",true).put("state","a_accepted").put("completed",completed).put("note","A 已接收命令；画面是否已更新无法由此回执确认。").toString()
    }

    @Volatile private var lastCommandState="commit_unknown"
    private fun queueACommand(kind:Int,payload:ByteArray):Long? {
        if(payload.size>ACommandProtocol.maxPayload) throw IllegalArgumentException("UART payload too large")
        val bridge=exchange(read=true,reg=ACommandProtocol.regBridgeId,value=0,retries=2,timeoutMs=220) ?: run { lastCommandState="bridge_unavailable"; return null }
        if(bridge.op!=2 || bridge.value!=ACommandProtocol.bridgeId) { lastCommandState="bridge_unavailable"; return null }
        val current=exchange(read=true,reg=ACommandProtocol.regToken,value=0,retries=2,timeoutMs=220)?.takeIf { it.op==2 }?.value
            ?: run { lastCommandState="bridge_unavailable"; return null }
        val token=ACommandProtocol.nextToken(current)
        lastAgentActionToken=token
        val stages=ACommandProtocol.stages(kind,payload)
        for((reg,value) in stages) {
            val ack=exchange(read=false,reg=reg,value=value,retries=3,timeoutMs=240)
            if(ack?.op!=2) { lastCommandState="stage_failed"; return null }
        }
        val commit=exchange(read=false,reg=ACommandProtocol.regCommit,value=token,retries=1,timeoutMs=500)
        if(commit==null) { lastCommandState="commit_unknown"; return null }
        if(commit.op==3) { lastCommandState="busy"; return null }
        lastCommandState="b_queued"; return token
    }

    private fun exchange(read:Boolean,reg:Int,value:Long,retries:Int,timeoutMs:Int):ControlProtocol.Reply? = synchronized(controlIo) {
        val s=control ?: return@synchronized null
        val target=try { InetAddress.getByName(board) } catch(_:Exception) { return@synchronized null }
        repeat(retries+1) {
            val seq=(++controlSeq) and 65535
            val req=if(read) ControlProtocol.read(seq,reg) else ControlProtocol.write(seq,reg,value)
            try {
                s.send(DatagramPacket(req,req.size,target,5000))
                val deadline=SystemClock.elapsedRealtime()+timeoutMs
                val data=ByteArray(64); val packet=DatagramPacket(data,data.size)
                while(!s.isClosed && SystemClock.elapsedRealtime()<deadline) {
                    s.soTimeout=maxOf(1,(deadline-SystemClock.elapsedRealtime()).toInt())
                    try {
                        packet.length=data.size; s.receive(packet)
                        if(packet.address!=target || packet.port!=5000) continue
                        val parsed=ControlProtocol.reply(data,packet.length,seq,reg) ?: continue
                        controlSeen=System.nanoTime()
                        return@synchronized parsed
                    } catch(_:SocketTimeoutException) { break }
                }
            } catch(_:Exception) { if(s.isClosed) return@synchronized null }
        }
        null
    }

    private fun waitA(stateToken:Long,timeoutMs:Long):String {
        val deadline=SystemClock.elapsedRealtime()+timeoutMs
        val terminal=mapOf(7 to "a_rejected",8 to "busy",9 to "uart_error",10 to "ack_timeout",11 to "cpu_fault")
        while(SystemClock.elapsedRealtime()<deadline && control?.isClosed==false) {
            val token=exchange(true,ACommandProtocol.regToken,0,0,120)?.takeIf { it.op==2 }?.value
            val state=exchange(true,ACommandProtocol.regState,0,0,120)?.takeIf { it.op==2 }?.value?.toInt()
            if(token==stateToken && state==5) return "a_accepted"
            if(token==stateToken && state!=null && terminal.containsKey(state)) return terminal.getValue(state)
            try { Thread.sleep(45) } catch(_:InterruptedException) { Thread.currentThread().interrupt(); return "interrupted" }
        }
        return "ack_timeout"
    }
}
