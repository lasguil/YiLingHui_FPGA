package com.efinity.ti60

import android.app.Activity
import android.os.Bundle
import android.view.*
import android.webkit.*
import android.widget.*
import android.content.ContentValues
import android.content.ClipData
import android.content.ClipboardManager
import android.provider.MediaStore
import android.net.Uri
import android.Manifest
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import java.util.concurrent.Executors

class MainActivity: Activity() {
    private lateinit var engine: Engine
    private lateinit var server: LocalHttpServer
    private lateinit var web: WebView
    private lateinit var root: android.widget.FrameLayout
    private val files=Executors.newSingleThreadExecutor()
    private var previewImmersive=false
    private var savedSystemUi=0
    private var savedCutoutMode=0
    private var fullscreen: View?=null
    private var pendingConnect: Pair<String,String>?=null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root=FrameLayout(this)
        root.setOnApplyWindowInsetsListener { v,i ->
            if(previewImmersive) {
                val cutout=i.displayCutout
                v.setPadding(cutout?.safeInsetLeft?:0,cutout?.safeInsetTop?:0,cutout?.safeInsetRight?:0,cutout?.safeInsetBottom?:0)
            } else v.setPadding(i.systemWindowInsetLeft,i.systemWindowInsetTop,i.systemWindowInsetRight,i.systemWindowInsetBottom)
            i
        }
        setContentView(root)
        engine=Engine(this); Diagnostics.log("app create sdk=${Build.VERSION.SDK_INT}"); server=LocalHttpServer(assets.open("index.html").use { it.readBytes().toString(Charsets.UTF_8) },object: HttpBackend {
            override fun frame()=engine.latest
            override fun status()=engine.status().toString(2)
            override fun registers()=engine.registerJson().toString()
            override fun session(body: String) { engine.session(org.json.JSONObject(body)) }
            override fun api(path:String,body:String)=engine.api(path,body)
            override fun streamError() { engine.decodeErrors.incrementAndGet() }
            override fun clientDelta(delta: Long) { engine.clients.addAndGet(delta) }
            override fun frameSent() { engine.httpFrames.incrementAndGet() }
        }, assets = assets)
        web=WebView(this)
        if(applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) WebView.setWebContentsDebuggingEnabled(true)
        with(web.settings) {
            javaScriptEnabled=true; domStorageEnabled=true; allowFileAccess=false; allowContentAccess=false
            mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW; setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture=true
        }
        web.webViewClient=object: WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val u=request.url
                if(u.scheme!="http" || u.host!="127.0.0.1" || u.port!=server.port) return true
                if(u.path=="/network-permission") {
                    if(android.os.Build.VERSION.SDK_INT>=36) requestPermissions(arrayOf("android.permission.NEARBY_WIFI_DEVICES"),16)
                    else Toast.makeText(this@MainActivity,"当前 targetSdk 35 默认通过 INTERNET 访问局域网",Toast.LENGTH_LONG).show()
                    return true
                }
                if(u.path=="/save-snapshot" || u.path=="/save-stats") { save(u.path=="/save-snapshot"); return true }
                return false
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                val u=request.url
                if(u.scheme!="http" || u.host!="127.0.0.1" || u.port!=server.port)
                    return WebResourceResponse("text/plain","UTF-8",403,"Forbidden",emptyMap(),java.io.ByteArrayInputStream(byteArrayOf()))
                return null
            }
        }
        web.webChromeClient=object: WebChromeClient() {
            override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                val level=m.messageLevel()
                if(level==ConsoleMessage.MessageLevel.ERROR || level==ConsoleMessage.MessageLevel.WARNING)
                    Diagnostics.log("js[$level] ${m.message()} @${m.sourceId()}:${m.lineNumber()}")
                return true
            }
            override fun onShowCustomView(view: View, cb: CustomViewCallback) {
                if(fullscreen!=null) { cb.onCustomViewHidden(); return }
                fullscreen=view; root.addView(view); web.visibility=View.GONE
                setPreviewLandscape(true)
            }
            override fun onHideCustomView() {
                fullscreen?.let { root.removeView(it) }; fullscreen=null; web.visibility=View.VISIBLE
                setPreviewLandscape(false)
            }
        }
        root.addView(web)
        web.addJavascriptInterface(object {
            @JavascriptInterface
            fun connectBoard(ssid: String, pass: String): String {
                val clean=ssid.trim()
                if(clean.isEmpty()) return "SSID 不能为空"
                Diagnostics.log("bridge connect request ssid=$clean")
                runOnUiThread {
                    val required=if(Build.VERSION.SDK_INT>=33)
                        arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
                    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
                    val missing=required.filter { checkSelfPermission(it)!=PackageManager.PERMISSION_GRANTED }
                    if(missing.isNotEmpty()) {
                        Diagnostics.log("permission request: ${required.joinToString(",")}")
                        pendingConnect=clean to pass
                        requestPermissions(required,17)
                    } else {
                        engine.connectBoard(clean,pass)
                    }
                }
                return "正在连接 VONETS…"
            }
            @JavascriptInterface
            fun rememberNetworkProfile(ssid:String,pass:String) {
                engine.rememberWifiProfile(ssid,pass)
            }
            @JavascriptInterface
            fun exportLogs(): String {
                runOnUiThread { this@MainActivity.exportLog() }
                return "正在导出日志…"
            }
            @JavascriptInterface
            fun setPreviewFullscreen(on: Boolean): String {
                runOnUiThread { setPreviewLandscape(on) }
                return if(on) "横屏" else "恢复"
            }
        }, "AndroidBridge")
        web.loadUrl(server.origin)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==17) {
            val pending=pendingConnect; pendingConnect=null
            if(pending!=null && grantResults.isNotEmpty() && grantResults.all { it==PackageManager.PERMISSION_GRANTED }) {
                Diagnostics.log("permission granted")
                engine.connectBoard(pending.first,pending.second)
                Toast.makeText(this,"权限已允许，正在连接 VONETS…",Toast.LENGTH_SHORT).show()
            } else {
                Diagnostics.log("permission denied")
                Toast.makeText(this,"未允许 Wi-Fi/附近设备权限，无法自动连接 VONETS",Toast.LENGTH_LONG).show()
            }
            return
        }
        if(requestCode==18) {
            engine.agentWifiPermissionResult(grantResults.isNotEmpty() && grantResults.all { it==PackageManager.PERMISSION_GRANTED })
            return
        }
        if(requestCode==16) Toast.makeText(this,if(grantResults.firstOrNull()==android.content.pm.PackageManager.PERMISSION_GRANTED) "附近设备权限已允许，请重新开始接收" else "权限未允许；若启用了 Android 16 局域网限制，请到设置中恢复权限",Toast.LENGTH_LONG).show()
    }
    private fun setPreviewLandscape(on: Boolean) {
        if(on && !previewImmersive) {
            savedSystemUi=window.decorView.systemUiVisibility
            savedCutoutMode=window.attributes.layoutInDisplayCutoutMode
        }
        previewImmersive=on
        root.setBackgroundColor(if(on) android.graphics.Color.BLACK else android.graphics.Color.TRANSPARENT)
        window.attributes=window.attributes.apply {
            layoutInDisplayCutoutMode=if(on) WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER else savedCutoutMode
        }
        applyPreviewSystemBars()
        requestedOrientation=if(on) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        root.requestApplyInsets()
    }
    @Suppress("DEPRECATION")
    private fun applyPreviewSystemBars() {
        window.decorView.systemUiVisibility=if(previewImmersive)
            View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            else savedSystemUi
        if(Build.VERSION.SDK_INT>=30) window.insetsController?.let {
            if(previewImmersive) {
                it.systemBarsBehavior=WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                it.hide(WindowInsets.Type.systemBars())
            } else it.show(WindowInsets.Type.systemBars())
        }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if(hasFocus && previewImmersive) applyPreviewSystemBars()
    }
    private fun exportLog() {
        Diagnostics.log("export log requested")
        val text = Diagnostics.dump() + "\n\n=== status ===\n" + engine.status().toString(2)
        files.execute {
            try {
                val name = "Ti60_log_${System.currentTimeMillis()}.txt"
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Ti60")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: error("无法创建日志文件")
                try {
                    (contentResolver.openOutputStream(uri) ?: error("无法写入日志")).use { it.write(text.toByteArray()) }
                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }
                runOnUiThread { Toast.makeText(this@MainActivity, "日志已保存：$name", Toast.LENGTH_LONG).show() }
            } catch (e: Exception) {
                Diagnostics.log("export log failed: ${e.message}")
                val cm = getSystemService(ClipboardManager::class.java)
                val copied = cm != null && runCatching {
                    cm.setPrimaryClip(ClipData.newPlainText("Ti60 log", text))
                }.isSuccess
                runOnUiThread {
                    val msg = if(copied) "日志已复制到剪贴板（文件保存失败：${e.message}）" else "日志导出失败：${e.message}"
                    Toast.makeText(this@MainActivity, msg, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun save(snapshot: Boolean) {
        files.execute {
            try {
                val data=if(snapshot) engine.latest?.jpeg ?: error("暂无完整 JPEG") else engine.status().toString(2).toByteArray()
                val name="Ti60_${System.currentTimeMillis()}.${if(snapshot) "jpg" else "json"}"
                val values=ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME,name)
                    put(MediaStore.MediaColumns.MIME_TYPE,if(snapshot) "image/jpeg" else "application/json")
                    put(MediaStore.MediaColumns.RELATIVE_PATH,if(snapshot) "Pictures/Ti60" else "Download/Ti60")
                    put(MediaStore.MediaColumns.IS_PENDING,1)
                }
                val collection=if(snapshot) MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Downloads.EXTERNAL_CONTENT_URI
                val uri=contentResolver.insert(collection,values) ?: error("无法创建文件")
                try {
                    (contentResolver.openOutputStream(uri) ?: error("无法写入文件")).use { it.write(data) }
                    contentResolver.update(uri,ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING,0) },null,null)
                } catch(e: Exception) { contentResolver.delete(uri,null,null); throw e }
                runOnUiThread { Toast.makeText(this,"已保存：$name",Toast.LENGTH_LONG).show() }
            } catch(e: Exception) { runOnUiThread { Toast.makeText(this,"保存失败：${e.message}",Toast.LENGTH_LONG).show() } }
        }
    }
    override fun onResume() { super.onResume(); Diagnostics.log("app resume"); if(::engine.isInitialized) engine.resume(); if(::web.isInitialized) web.onResume() }
    override fun onPause() { Diagnostics.log("app pause"); if(::engine.isInitialized) engine.pause(); if(::web.isInitialized) web.onPause(); super.onPause() }
    override fun onDestroy() { Diagnostics.log("app destroy"); if(::web.isInitialized) { web.stopLoading(); web.destroy() }; if(::server.isInitialized) server.close(); if(::engine.isInitialized) engine.close(); files.shutdown(); super.onDestroy() }
    @Deprecated("Activity API") override fun onBackPressed() { if(fullscreen!=null) web.webChromeClient?.onHideCustomView() else super.onBackPressed() }
}
