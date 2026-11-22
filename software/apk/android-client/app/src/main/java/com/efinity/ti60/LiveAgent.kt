package com.efinity.ti60

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Semaphore
import java.net.HttpURLConnection
import java.net.URL

/** Native tool-calling Agent for the live FPGA camera app. */
object LiveAgent {
    @Volatile private var activeAgentConnection:HttpURLConnection?=null
    fun cancelCurrentAgentRequest() { try { activeAgentConnection?.disconnect() } catch(_:Exception) { } }
    /** A reservation may be acquired on an HTTP thread and released by the Agent worker. */
    class CommandGate {
        private val semaphore = Semaphore(1, true)
        fun tryAcquire(): Boolean = semaphore.tryAcquire()
        fun release() = semaphore.release()
    }
    const val endpoint = "https://api.deepseek.com/chat/completions"
    const val maxText = 1200
    /** LUT 目录（与 assets/luts 一致；swatch 为两端口渐变色）。 */
    val lutCatalog = listOf(
        listOf("identity", "原始", "原始", "#202020", "#e0e0e0"),
        listOf("warm", "暖色", "调色", "#000810", "#fffffb"),
        listOf("aged", "泛黄", "调色", "#080c1c", "#ffffdb"),
        listOf("verdant", "泛绿", "调色", "#000814", "#efefbe"),
        listOf("memory", "记忆", "黑白", "#101c20", "#e7e3d7"),
        listOf("cine", "青橙", "调色", "#00080c", "#ffffeb"),
        listOf("neon", "酸性霓虹", "渐变映射", "#0c0024", "#efff9a"),
        listOf("cyan", "青版", "渐变映射", "#080c20", "#ebf3ff"),
        listOf("forest", "森绿", "渐变映射", "#081810", "#f3ebcb"),
        listOf("thermal", "红外伪彩", "渐变映射", "#000008", "#fffbe3"),
        listOf("sunset", "日落", "渐变映射", "#18082c", "#ffef9a"),
        listOf("duotone", "青橙影调", "渐变映射", "#082830", "#ff9a41"),
        listOf("invert", "负片", "曲线", "#ffffff", "#000000")
    )
    val actionIds = mapOf(
        "open_menu" to 2, "close" to 40, "pause_toggle" to 7, "view_next" to 6,
        "model_next" to 39, "model_prev" to 38, "color_gray" to 12,
        "color_curve" to 11, "color_duotone" to 13, "color_dots" to 14,
        "table_next" to 10, "table_prev" to 9, "ai_plus" to 18,
        "ai_minus" to 17, "fx_plus" to 16, "fx_minus" to 15,
        "sat_plus" to 20, "sat_minus" to 19,
        "keep_toggle" to 23, "out_minus" to 21, "out_plus" to 22,
        "ui_hide_all" to 45, "ui_restore" to 46, "wave" to 47,
        "clean" to 8, "mode" to 1, "adjust" to 3, "keep_page" to 4, "rgb_page" to 5, "range" to 24, "rgb_back" to 25,
        "b0_minus" to 26, "b0_plus" to 27, "b1_minus" to 28, "b1_plus" to 29, "b2_minus" to 30, "b2_plus" to 31,
        "b3_minus" to 32, "b3_plus" to 33, "b4_minus" to 34, "b4_plus" to 35, "b5_minus" to 36, "b5_plus" to 37,
        "adjust_basic" to 41, "adjust_keep" to 42, "reset" to 43, "vflip" to 44
    )
    val videoModes = (0..3).associate { "video_mode_$it" to it }
    val allowed = actionIds.keys + videoModes.keys
    val names = mapOf(
        "open_menu" to "切换调色菜单", "close" to "关闭面板", "pause_toggle" to "暂停/恢复切换",
        "view_next" to "切换视图（相对轮换）", "model_next" to "下一模型", "model_prev" to "上一模型",
        "color_gray" to "灰度方案", "color_curve" to "曲线方案", "color_duotone" to "双色点方案",
        "color_dots" to "彩色点方案", "table_next" to "下一张表", "table_prev" to "上一张表",
        "ai_plus" to "AI 强度 +5%", "ai_minus" to "AI 强度 −5%", "fx_plus" to "效果强度 +5%",
        "fx_minus" to "效果强度 −5%", "sat_plus" to "饱和度 +5%", "sat_minus" to "饱和度 −5%",
        "keep_toggle" to "Keep Color 保色开关", "out_minus" to "输出饱和度 −5%", "out_plus" to "输出饱和度 +5%",
        "ui_hide_all" to "完全隐藏板端 UI", "ui_restore" to "恢复板端 UI"
    ) + videoModes.keys.associateWith { "输入视频模式 ${it.substringAfterLast('_')}" }

    class AgentFailure(message: String) : Exception(message)
    data class ConnectionLease(val connection: HttpURLConnection, val release: () -> Unit = {})

    data class ToolCall(val id:String, val name:String, val arguments:JSONObject)
    data class AgentTurn(val assistantMessage:JSONObject, val calls:List<ToolCall>, val text:String?)

    private fun tool(name:String, description:String, properties:JSONObject=JSONObject(), required:List<String> = emptyList()) =
        JSONObject().put("type","function").put("function",JSONObject().put("name",name).put("description",description)
            .put("parameters",JSONObject().put("type","object").put("properties",properties)
                .put("required",JSONArray(required)).put("additionalProperties",false)))

    /** Native tools are the complete set of app functions the Agent can invoke. */
    fun agentTools():JSONArray {
        val actionNames=allowed.sorted()
        return JSONArray()
            .put(tool("inspect_app","读取本机 App、FPGA 控制桥、视频帧、寄存器、Wi-Fi 与公网状态。",JSONObject()))
            .put(tool("network_status","读取当前 Wi-Fi/VONETS、路由、公网、手机 IPv4 和连接状态。",JSONObject()))
            .put(tool("observe_screen","读取最新画面的亮度、对比度、饱和度、冷暖和主色统计。开启连同画面发送且有近期帧时，模型请求附带最新 JPEG。",JSONObject()))
            .put(tool("reconnect_board","用 App 保存的 VONETS 凭据重新连接板卡并恢复视频/控制接收。",JSONObject()))
            .put(tool("set_receive_session","启动或停止 App 的视频/控制接收会话。",JSONObject()
                .put("action",JSONObject().put("type","string").put("enum",JSONArray(listOf("start","stop"))))
                .put("board",JSONObject().put("type","string").put("description","IPv4 address"))
                .put("port",JSONObject().put("type","integer"))
                .put("timeout_ms",JSONObject().put("type","integer"))
                .put("simulation",JSONObject().put("type","boolean")), listOf("action")))
            .put(tool("control_action","执行设备按键动作或输入视频模式，count 为重复次数。返回接收回执、token 和已完成动作。",JSONObject()
                .put("action",JSONObject().put("type","string").put("enum",JSONArray(actionNames)))
                .put("count",JSONObject().put("type","integer").put("minimum",1)), listOf("action")))
            .put(tool("set_parameter","绝对设置风格、调色表、AI 强度、效果强度、饱和度、局部保色、RGB范围、挥手模式或暂停。pause 0=恢复 1=暂停（不依赖挥手模式）；model 0..28，table 0..12，ai/fx 0..100，sat 0..200，keep 0/1，keep_range 0红/1绿/2蓝，b0..b5 为 R下限/R上限/G下限/G上限/B下限/B上限，0..255且下限不能大于上限；wave 0=关闭 1=核心板 2=扩展板。",JSONObject()
                .put("field",JSONObject().put("type","string").put("enum",JSONArray(DeviceParameters.specs.keys.toList())))
                .put("value",JSONObject().put("type","integer")), listOf("field","value")))
            .put(tool("set_ui_visibility","设置视频中的板端 UI：visible=false 隐藏，true 恢复。",JSONObject()
                .put("visible",JSONObject().put("type","boolean")), listOf("visible")))
            .put(tool("check_device_receipt","查询并等待最近一次 FPGA 命令的接收回执。",JSONObject()))
            .put(tool("read_diagnostics","读取 App 最近连接日志，帮助定位 Wi-Fi、视频和控制链路问题。",JSONObject()))
    }

    fun parseAgentTurn(choice:JSONObject):AgentTurn {
        val message=choice.optJSONObject("message") ?: throw AgentFailure("Agent 响应缺少 message")
        val reason=choice.optString("finish_reason")
        val callsJson=message.optJSONArray("tool_calls") ?: JSONArray()
        val calls=ArrayList<ToolCall>(callsJson.length())
        for(i in 0 until callsJson.length()) {
            val row=callsJson.optJSONObject(i) ?: throw AgentFailure("Agent 工具调用结构无效")
            if(row.optString("type")!="function") throw AgentFailure("Agent 请求了未知工具类型")
            val id=row.optString("id")
            val fn=row.optJSONObject("function") ?: throw AgentFailure("Agent 工具调用缺少 function")
            val name=fn.optString("name")
            if(id.isBlank() || name !in toolNames) throw AgentFailure("Agent 请求了未开放的工具：$name")
            val args=try { JSONObject(fn.optString("arguments")) } catch(_:Exception) { throw AgentFailure("工具 $name 的参数 JSON 无效") }
            calls += ToolCall(id,name,args)
        }
        if(calls.isEmpty() && reason!="stop") throw AgentFailure("Agent 响应未完整结束：$reason")
        if(calls.isNotEmpty() && reason !in setOf("tool_calls","stop")) throw AgentFailure("Agent 工具调用未完整结束：$reason")
        return AgentTurn(JSONObject(message.toString()),calls,message.optString("content").takeIf { it!="null" })
    }

    private val toolNames=setOf("inspect_app","network_status","observe_screen","reconnect_board","set_receive_session",
        "control_action","set_parameter","set_ui_visibility","check_device_receipt","read_diagnostics")

    const val maxContextCharacters = 500_000

    /** Count Unicode code points in message/tool JSON, excluding image URL payloads. */
    internal fun agentContextCharacters(messages:JSONArray,tools:JSONArray):Int {
        val textMessages=JSONArray(messages.toString())
        for(i in 0 until textMessages.length()) {
            val parts=textMessages.optJSONObject(i)?.optJSONArray("content") ?: continue
            for(j in 0 until parts.length()) {
                val part=parts.optJSONObject(j) ?: continue
                if(part.optString("type")=="image_url") part.put("image_url",JSONObject())
            }
        }
        val text=textMessages.toString()+tools.toString()
        return text.codePointCount(0,text.length)
    }

    internal fun validateAgentContext(messages:JSONArray,tools:JSONArray) {
        val count=agentContextCharacters(messages,tools)
        if(count>maxContextCharacters) throw AgentFailure(
            "上下文长度超过 500,000 字符（当前 $count 字符），请新建对话。")
    }

    /** One real tool-calling turn; caller appends assistant/tool messages and continues Pi-style. */
    fun deepSeekAgentTurn(history:JSONArray,key:String,model:String,image:ByteArray?=null,
                          opener:(URL)->ConnectionLease={ ConnectionLease(it.openConnection() as HttpURLConnection) }):AgentTurn {
        if(key.isBlank() || key.length>500) throw AgentFailure("DeepSeek API Key 未填写")
        if(model.isBlank() || model.length>80) throw AgentFailure("model 名称无效")
        val messages=JSONArray().put(JSONObject().put("role","system").put("content",agentSystemPrompt()))
        for(i in 0 until history.length()) messages.put(history.get(i))
        if(image!=null) messages.put(JSONObject().put("role","user").put("content",JSONArray()
            .put(JSONObject().put("type","text").put("text","最新设备画面。"))
            .put(JSONObject().put("type","image_url").put("image_url",JSONObject()
                .put("url","data:image/jpeg;base64,"+java.util.Base64.getEncoder().encodeToString(image))))))
        val tools=agentTools()
        validateAgentContext(messages,tools)
        val body=JSONObject().put("model",model.trim()).put("messages",messages).put("tools",tools)
            .put("tool_choice","auto").put("thinking",JSONObject().put("type","enabled")).put("stream",false)
        val lease=opener(URL(endpoint)); val conn=lease.connection
        activeAgentConnection=conn
        try {
            conn.instanceFollowRedirects=false; conn.requestMethod="POST"; conn.connectTimeout=10000; conn.readTimeout=180000
            conn.doOutput=true; conn.setRequestProperty("Authorization","Bearer $key"); conn.setRequestProperty("Content-Type","application/json")
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code=conn.responseCode
            if(code !in 200..299) throw AgentFailure("DeepSeek HTTP $code")
            val payload=conn.inputStream.use { input ->
                val out=java.io.ByteArrayOutputStream(); val buf=ByteArray(4096)
                while(true) { val n=input.read(buf); if(n<0) break; if(out.size()+n>8*1024*1024) throw AgentFailure("DeepSeek 响应过大"); out.write(buf,0,n) }
                out.toByteArray().toString(Charsets.UTF_8)
            }
            val choices=JSONObject(payload).optJSONArray("choices") ?: throw AgentFailure("DeepSeek 响应格式无效")
            if(choices.length()!=1) throw AgentFailure("DeepSeek 未返回单一完整响应")
            return parseAgentTurn(choices.getJSONObject(0))
        } catch(e:AgentFailure) { throw e }
        catch(e:Exception) { throw AgentFailure("Agent 网络请求失败：${e.message ?: "请检查网络和 API Key"}") }
        finally { if(activeAgentConnection===conn) activeAgentConnection=null; conn.disconnect(); lease.release() }
    }

    private fun agentSystemPrompt() = """易灵绘是一套基于 FPGA 的实时视觉创作系统，将摄像头画面转换为多种艺术风格，并提供 LUT 调色、效果强度、饱和度、局部保色、画面对比和暂停等功能。手机 App 可无线查看实时画面、控制板卡，并通过自然语言助手组合调整视觉效果。

你是易灵绘 FPGA 实时视觉系统的助手，通过以下接口完成用户的查询和操作，用简洁中文回复。
回复简洁，尽量使用纯文本，避免 Markdown 格式。

可用接口：
- inspect_app：读取 App、视频、控制桥、寄存器和网络状态。
- network_status：读取 Wi-Fi、VONETS、路由和公网状态。
- observe_screen：读取当前画面的亮度、对比度、饱和度、冷暖和主色统计。开启“连同画面发送”且有近期视频帧时，每轮模型请求附带最新 JPEG。
- reconnect_board：使用已保存的 VONETS 凭据连接板卡并恢复接收。
- set_receive_session：启动或停止视频/控制接收，可指定板卡地址、端口和超时。
- set_parameter：按绝对数值设置风格、LUT、强度、饱和度、保色、RGB 范围、挥手模式和暂停状态。字段与范围见工具定义。
- control_action：执行设备按键动作或切换输入视频模式，count 为重复次数。支持配色模式、视图轮换、翻转、重置、菜单操作和参数相对步进。
- set_ui_visibility：显示或隐藏视频中的板端 UI。
- check_device_receipt：查询最近一次设备命令的接收回执。
- read_diagnostics：读取 App 连接日志。

$knowledge

LUT 表、配色模式和 AI 风格是彼此独立的选择，可分别设置并组合使用；选择 LUT 表不等于选择配色模式或 AI 风格。
配色动作：color_curve=RGB曲线，color_gray=灰度配色，color_duotone=双调网点，color_dots=彩色网点。
输入模式：video_mode_0=1080p30，video_mode_1=720p30，video_mode_2=480p30，video_mode_3=480p60。
设备提供命令接收回执，不提供当前效果参数读回。视频中的板端 UI 可显示风格，LUT 位于二级菜单；暂停期间不能切换风格。"""

    data class Step(val action: String, val count: Int)
    data class Plan(val reply: String, val steps: List<Step>, val observeAgain: Boolean = false) {
        fun json() = JSONObject().put("reply", reply).put("steps", JSONArray().also { array ->
            steps.forEach { array.put(JSONObject().put("action", it.action).put("count", it.count)) }
        }).also { if(observeAgain) it.put("observe_again",true) }
        fun preview() = JSONArray().also { rows -> steps.forEach { rows.put(JSONObject()
            .put("action", it.action).put("count", it.count).put("label", names[it.action] ?: it.action)) } }
    }

    fun validateText(value: String): String {
        if (value.isBlank() || value.length > maxText) throw AgentFailure("请输入 1–$maxText 字符的请求")
        return value.trim()
    }

    private fun parameterRegex() = "(?:AI\\s*(?:强度)?|效果\\s*(?:强度)?|特效\\s*(?:强度)?|饱和度)"
    private fun relativePattern() = Regex("(?i)(?:(增加|提高|加|降低|减少|减)\\s*(${parameterRegex()})|(${parameterRegex()})\\s*(增加|提高|加|降低|减少|减))\\s*(\\d+)\\s*[%％]?")
    private fun preflightAbsolute(text:String) {
        val param=Regex("(?i)${parameterRegex()}")
        val number=Regex("\\d+\\s*[%％]?")
        val relative=relativePattern().findAll(text).toList()
        val setters=Regex("(?i)(设置|设为|设到|设定|调到|调成|调整为|改成|变成|达到|提高到|降低到|增至|降至)")
        for(p in param.findAll(text)) {
            val start=(p.range.first-22).coerceAtLeast(0); val end=(p.range.last+23).coerceAtMost(text.length)
            val nearby=text.substring(start,end)
            if(number.containsMatchIn(nearby)) {
                val authorized=relative.any { it.range.first>=start && it.range.last<end && it.value.contains(p.value,true) }
                if(!authorized || setters.containsMatchIn(nearby) || Regex("(?i)(到|为|成)\\s*\\d").containsMatchIn(nearby))
                    throw AgentFailure("未提供绝对值读回，不能验证目标数值；请改用±5%相对操作。未请求云端，未执行。")
            }
        }
    }

    fun validatePlan(json: JSONObject): Plan {
        if (json.length() !in 2..3 || !json.has("reply") || !json.has("steps") || (json.length()==3 && !json.has("observe_again"))) throw AgentFailure("计划字段无效；未发送设备命令")
        val reply = json.opt("reply") as? String ?: throw AgentFailure("计划说明无效；未发送设备命令")
        val array = json.opt("steps") as? JSONArray ?: throw AgentFailure("计划步骤无效；未发送设备命令")
        val steps = mutableListOf<Step>()
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: throw AgentFailure("步骤结构无效；未发送设备命令")
            if (obj.length() != 2 || !obj.has("action") || !obj.has("count")) throw AgentFailure("步骤字段无效；未发送设备命令")
            val action = obj.opt("action") as? String ?: throw AgentFailure("动作无效；未发送设备命令")
            val countValue = obj.opt("count")
            if (action !in allowed || countValue !is Int || countValue < 1)
                throw AgentFailure("动作不在白名单或次数越界；未发送设备命令")
            steps += Step(action, countValue)
        }
        val observe=json.opt("observe_again")
        if(observe!=null && observe !is Boolean) throw AgentFailure("观察标记无效；未发送设备命令")
        return Plan(reply, steps, observe==true)
    }

    /** 离线配方：当前固件可确定执行的部分（颜色模式为绝对动作）+ 诚实的表位置说明。 */
    class Recipe(val words: List<String>, val name: String, val mode: String, val note: String)
    val offlineRecipes = listOf(
        Recipe(listOf("霓虹", "赛博", "acid"), "赛博霓虹", "color_gray",
            "酸性霓虹表烧录后即为完整霓虹色带；当前固件先用灰度配色模式近似，请在菜单里把调色表切到色彩最浓的一张。"),
        Recipe(listOf("青版", "蓝晒", "印相"), "青版印相", "color_gray",
            "青版表烧录后即为蓝白印相；当前固件先用灰度配色模式，请在菜单把调色表切到冷调的一张。"),
        Recipe(listOf("日落", "熔金", "晚霞"), "落日熔金", "color_gray",
            "日落表烧录后即为紫红→橙金晚霞；当前固件先用灰度配色模式，请在菜单把调色表切到暖调的一张。"),
        Recipe(listOf("暖调胶片", "暖色胶片", "暖色"), "暖调胶片", "color_curve",
            "暖色表 + RGB 曲线模式就是完整暖调胶片；请在菜单确认调色表在暖色。"),
        Recipe(listOf("银盐", "黑白", "记忆黑白"), "银盐黑白", "color_gray",
            "灰度配色 + 原始表即纯灰度；请在菜单把调色表切回原始。"),
    )

    /** Small deterministic Chinese rules; this is explicitly not an LLM. */
    fun offlinePlan(text: String): Plan {
        val source = validateText(text)
        for (recipe in offlineRecipes) {
            if (recipe.words.any { source.contains(it, ignoreCase = true) }) {
                val plan = Plan("应用配方「${recipe.name}」：${recipe.note}（离线规则不是 LLM。）",
                    listOf(Step(if (recipe.mode == "color_gray") "color_gray" else "color_curve", 1)))
                return try { validatePlan(plan.json()) } catch (_: AgentFailure) { plan }
            }
        }
        val unsupported = listOf("3dlut", "3d lut", "空间效果", "绝对", "设为", "调到", "达到", "设置为")
        if (unsupported.any { source.contains(it, ignoreCase = true) })
            return Plan("缺少可读回的绝对参数状态或该能力不可用；未执行。请用“增加 AI 强度 5%”这类相对操作。离线规则不是 LLM。", emptyList())
        try { preflightAbsolute(source) } catch(e:AgentFailure) { return Plan(e.message+" 离线规则不是 LLM。", emptyList()) }
        var rest = source
        val steps = mutableListOf<Step>()
        val adjustment = relativePattern()
        for (m in adjustment.findAll(source).toList().asReversed()) {
            val amount = m.groupValues[5].toIntOrNull() ?: return Plan("相对调整须为 5% 的整数倍；未执行。离线规则不是 LLM。", emptyList())
            val count = amount / 5
            if (amount % 5 != 0 || count < 1) return Plan("相对调整须为 5% 的正整数倍；未执行。离线规则不是 LLM。", emptyList())
            val param=m.groupValues[2].ifEmpty { m.groupValues[3] }
            val verb=m.groupValues[1].ifEmpty { m.groupValues[4] }
            val key = when { param.startsWith("AI",true) -> "ai"; param.startsWith("饱和度") -> "sat"; else -> "fx" }
            val dir = if (verb in listOf("增加", "提高", "加")) "plus" else "minus"
            steps += Step("${key}_$dir", count)
            rest = rest.removeRange(m.range)
        }
        val rules = listOf(
            listOf("保留颜色", "局部保色", "keep color") to "keep_toggle",
            listOf("下一模型", "下一个模型", "模型下一个") to "model_next", listOf("上一模型", "上一个模型", "模型上一个") to "model_prev",
            listOf("切换视图", "换个视图", "下一个视图") to "view_next", listOf("灰度", "黑白") to "color_gray",
            listOf("曲线色", "曲线") to "color_curve", listOf("双色点") to "color_duotone", listOf("彩色点", "彩点") to "color_dots",
            listOf("打开菜单", "打开模式菜单", "开启菜单") to "open_menu", listOf("关闭面板", "关闭菜单") to "close",
            listOf("暂停", "恢复", "继续播放") to "pause_toggle", listOf("下一张表", "下一表") to "table_next",
            listOf("上一张表", "上一表") to "table_prev"
        )
        for ((words, action) in rules) if (words.any { rest.contains(it) }) {
            steps += Step(action, 1); words.forEach { rest = rest.replace(it, " ") }
        }
        for (i in 0..3) {
            val pattern = Regex("(?:输入模式|视频模式|模式)\\s*$i(?!\\d)")
            if (pattern.containsMatchIn(rest)) { steps += Step("video_mode_$i", 1); rest = pattern.replace(rest, " ") }
        }
        val residue = rest.replace(Regex("[\\s，,。；;和以及并的请帮我把切换调成设为到百分％强度输入视频模式选择aifx+\\-]", RegexOption.IGNORE_CASE), "")
        if (residue.isNotEmpty()) return Plan("离线规则未识别请求中的部分内容；未执行。离线规则不是 LLM。", emptyList())
        return try { validatePlan(Plan("离线规则生成了有限动作计划；离线规则不是 LLM。", steps).json()) }
        catch (_: AgentFailure) { Plan("计划超过安全动作上限；未执行。离线规则不是 LLM。", emptyList()) }
    }

    /** 离线场景推荐：按画面统计给确定性动作 + 理由（不是 LLM）。 */
    fun recommendFromScene(stats: SceneStats.Stats): Plan {
        val (name, mode, reason) = when {
            stats.brightnessMean < 90 -> Triple("落日熔金", "color_gray",
                "画面偏暗，日落类渐变映射的橙金高光段可以点亮主体；请在菜单把调色表切到暖调的一张")
            stats.warmth < -0.08 -> Triple("暖调胶片", "color_curve",
                "画面偏冷，暖色表的曲线能把色温拉回来")
            stats.saturationMean > 145 -> Triple("银盐黑白", "color_gray",
                "画面饱和度偏高，灰度配色更耐看；请在菜单把调色表切回原始")
            stats.saturationMean < 30 -> Triple("霓虹注入", "color_gray",
                "画面接近黑白，灰度配色能注入强色彩；请在菜单把调色表切到色彩最浓的一张")
            else -> Triple("青橙影调", "color_gray",
                "画面曝光与色彩均衡，灰度配色最稳妥地增加影调；请在菜单把调色表切到青橙类的一张")
        }
        return try { validatePlan(Plan("根据画面分析，我推荐「$name」：$reason。（离线规则不是 LLM。）",
            listOf(Step(if (mode == "color_curve") "color_curve" else "color_gray", 1))).json()) }
        catch (_: AgentFailure) { Plan("推荐计划超出动作上限；未执行。", emptyList()) }
    }

    /** Strict JSON parser rejects duplicate keys before JSONObject could hide them. */
    fun strictPlan(text: String): Plan {
        val parsed = StrictJson(text).parse() as? Map<*, *> ?: throw AgentFailure("DeepSeek JSON 结构无效；未执行")
        if (parsed.keys != setOf("reply", "steps") && parsed.keys != setOf("reply", "steps", "observe_again")) throw AgentFailure("计划字段无效；未执行")
        val reply = parsed["reply"] as? String ?: throw AgentFailure("计划说明无效；未执行")
        val rows = parsed["steps"] as? List<*> ?: throw AgentFailure("计划步骤无效；未执行")
        val steps = rows.map { row ->
            val obj = row as? Map<*, *> ?: throw AgentFailure("步骤结构无效；未执行")
            if (obj.keys != setOf("action", "count")) throw AgentFailure("步骤字段无效；未执行")
            val action = obj["action"] as? String ?: throw AgentFailure("动作无效；未执行")
            val count = obj["count"] as? Long ?: throw AgentFailure("count 必须是整数；未执行")
            if (action !in allowed || count !in 1..Int.MAX_VALUE.toLong()) throw AgentFailure("动作不在白名单或次数无效；未执行")
            Step(action, count.toInt())
        }
        val observe=parsed["observe_again"]
        if(parsed.containsKey("observe_again") && observe !is Boolean) throw AgentFailure("观察标记无效；未执行")
        return Plan(reply, steps, observe==true)
    }

    /** 表×颜色模式组合知识：与 PC 端 lut_library/core.py 同源（摘要版，不含曲线数值）。 */
    /** 实际上板的 26 个风格（顺序 = MODEL_PREV/NEXT 的目录序，来源 assets/styles/deploy）。 */
    val styleCatalog = listOf(
        "梵高星空", "波普漫画", "糖果", "点彩印象", "蓝调版画", "霓虹", "街头涂鸦", "赛博朋克",
        "极光", "水墨", "毕加索", "像素风", "剪纸", "卡通", "木刻版画", "浮世绘",
        "素描", "素描极简", "蓝晒水彩", "墨影刻痕", "tiktok", "日出印象", "铁锈", "抖动像素",
        "复古", "迷幻", "铜浮雕", "诺贝尔金箔", "彩色玻璃马赛克"
    )

    val styleScreenNames = listOf("VANGOGH","POPCOMIC","CANDY","POINTILL","BLUEPRINT","NEON","GRAFFITI","CYBERPUNK",
        "AURORA","INKWASH","PICASSO","PIXEL","PAPERCUT","CARTOON","WOODCUT","UKIYOE","SKETCH","MINIMAL",
        "CYANOTYPE","INKCARVE","TIKTOK","SUNRISE","RUST","DITHER","RETRO","PSY","COPPER","NOBEL","MOSAIC")
    val knowledge: String get() = """风格索引（屏幕名/中文名）：${styleScreenNames.zip(styleCatalog).mapIndexed { index, entry -> "$index=${entry.first}/${entry.second}" }.joinToString("，")}。
LUT 索引（屏幕名/中文名）：${lutCatalog.mapIndexed { index, entry -> "$index=${entry[0].uppercase()}/${entry[1]}" }.joinToString("，")}。0 为原始表。"""

    /** 组装 messages；image!=null 时按 OpenAI 视觉格式构造 content 数组（JVM 可测）。 */
    internal fun buildMessages(prompt: String, text: String, image: ByteArray?, sceneSummary: String?): JSONArray {
        val userContent: Any = if (image != null) JSONArray()
            .put(JSONObject().put("type", "text").put("text", text))
            .put(JSONObject().put("type", "image_url").put("image_url",
                JSONObject().put("url", "data:image/jpeg;base64," + java.util.Base64.getEncoder().encodeToString(image))))
        else text
        return JSONArray()
            .put(JSONObject().put("role", "system").put("content", prompt))
            .put(JSONObject().put("role", "user").put("content", userContent))
    }

    fun deepSeekPlan(text: String, key: String, model: String, image: ByteArray? = null, sceneSummary: String? = null, context: String? = null,
                     opener: (URL) -> ConnectionLease = { ConnectionLease(it.openConnection() as HttpURLConnection) }): Plan {
        val cleanText=validateText(text)
        if (key.isBlank() || key.length > 500) throw AgentFailure("DeepSeek API Key 未填写；未发送设备命令")
        if (model.isBlank() || model.length > 80) throw AgentFailure("model 名称无效；未发送设备命令")
        preflightAbsolute(cleanText)
        val prompt = """你是易灵绘设备的调色助手。动作会直接执行。只输出JSON：{"reply":字符串,"steps":[{"action":动作ID,"count":正整数}],"observe_again":布尔值}。可用动作：${allowed.sorted().joinToString(",")}。需要在执行后再次观察画面并决定后续操作时，将 observe_again 设为 true；完成或无需观察时设为 false。不要声称设备或画面已发生未经验证的变化。
$knowledge
${if (sceneSummary != null) "最新画面统计：$sceneSummary\n" else ""}${if(context!=null) "此前执行结果：$context\n" else ""}参数只能通过±5%按钮相对调整，绝不猜测绝对值。view_next只是相对轮换，pause_toggle是切换。不要给URL、命令、文件工具或任何其它动作。无法支持时返回steps空数组并说明。"""
        val body = JSONObject().put("model", model.trim()).put("messages", buildMessages(prompt, cleanText, image, sceneSummary))
            .put("response_format", JSONObject().put("type", "json_object")).put("thinking",JSONObject().put("type","enabled"))
            .put("stream", false)
        val lease = opener(URL(endpoint)); val conn=lease.connection
        try {
            conn.instanceFollowRedirects = false
            conn.requestMethod = "POST"; conn.connectTimeout = 10000; conn.readTimeout = 180000
            conn.doOutput = true; conn.setRequestProperty("Authorization", "Bearer $key"); conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code !in 200..299) throw AgentFailure("DeepSeek HTTP $code；未发送设备命令")
            val payload = conn.inputStream.use { input ->
                val out=java.io.ByteArrayOutputStream(); val buf=ByteArray(4096)
                while(true) { val n=input.read(buf); if(n<0) break; if(out.size()+n>8*1024*1024) throw AgentFailure("DeepSeek 响应过大；未执行"); out.write(buf,0,n) }
                out.toByteArray().toString(Charsets.UTF_8)
            }
            val choices = JSONObject(payload).optJSONArray("choices") ?: throw AgentFailure("DeepSeek 响应格式无效；未执行")
            if (choices.length() != 1) throw AgentFailure("DeepSeek 输出未完整结束；未执行")
            val choice = choices.getJSONObject(0)
            if (choice.optString("finish_reason") != "stop") throw AgentFailure("DeepSeek 输出未完整结束；未执行")
            return strictPlan(choice.getJSONObject("message").getString("content"))
        } catch (e: AgentFailure) { throw e }
        catch (_: Exception) { throw AgentFailure("DeepSeek 请求失败；请检查 Internet、DNS、时间和 API Key；未发送设备命令") }
        finally { conn.disconnect(); lease.release() }
    }

    private class StrictJson(private val source: String) {
        private var p = 0
        fun parse(): Any? { val value = value(0); ws(); if (p != source.length) fail(); return value }
        private fun value(depth: Int): Any? { if (depth > 16) fail(); ws(); if (p >= source.length) fail(); return when (source[p]) {
            '{' -> obj(depth); '[' -> array(depth); '"' -> string(); 't' -> literal("true", true); 'f' -> literal("false", false); 'n' -> literal("null", null)
            in '0'..'9', '-' -> number(); else -> fail()
        } }
        private fun obj(depth: Int = 0): Map<String, Any?> { p++; ws(); val out = linkedMapOf<String, Any?>(); if (eat('}')) return out
            while (true) { ws(); val k = string(); if (out.containsKey(k)) fail(); ws(); expect(':'); val v = value(depth + 1); out[k] = v; ws(); if (eat('}')) return out; expect(',') }
        }
        private fun array(depth: Int = 0): List<Any?> { p++; ws(); val out = mutableListOf<Any?>(); if (eat(']')) return out
            while (true) { out += value(depth + 1); ws(); if (eat(']')) return out; expect(',') }
        }
        private fun string(): String { expect('"'); val start = p-1; var escaped = false
            while (p < source.length) { val c = source[p++]; if (!escaped && c == '"') return try { JSONObject("{\"v\":${source.substring(start, p)}}").getString("v") } catch (_: Exception) { fail() }; if (!escaped && c == '\\') escaped = true else escaped = false; if (c < ' ' && !escaped) fail() }
            fail()
        }
        private fun number(): Long { val s=p; if (source[p]=='-') p++; if (p>=source.length) fail(); if (source[p]=='0') p++ else { if(source[p] !in '1'..'9') fail(); while(p<source.length && source[p].isDigit()) p++ }; if (p<source.length && source[p] in ".eE") fail(); return source.substring(s,p).toLongOrNull() ?: fail() }
        private fun <T> literal(text: String, value: T): T { if (!source.startsWith(text,p)) fail(); p+=text.length; return value }
        private fun ws() { while (p<source.length && source[p] in " \r\n\t") p++ }
        private fun eat(c: Char): Boolean { if (p<source.length && source[p]==c) { p++; return true }; return false }
        private fun expect(c: Char) { if (!eat(c)) fail() }
        private fun fail(): Nothing = throw AgentFailure("DeepSeek JSON 无效或含重复字段；未发送设备命令")
    }
}
