package com.efinity.ti60

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class LiveAgentTest {
    @org.junit.Test fun colorActionsMatchBoardOneProtocol() {
        org.junit.Assert.assertEquals(11, LiveAgent.actionIds["color_curve"])
        org.junit.Assert.assertEquals(12, LiveAgent.actionIds["color_gray"])
    }
    @Test fun onlyExactAllowlistedPlanSchemaIsAccepted() {
        val plan=LiveAgent.strictPlan("{\"reply\":\"done\",\"steps\":[{\"action\":\"ai_plus\",\"count\":2},{\"action\":\"video_mode_2\",\"count\":1}]}")
        assertEquals(2,plan.steps.size); assertEquals(3,plan.steps.sumOf { it.count })
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[],\"url\":\"https://bad\"}") }
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"reply\":\"y\",\"steps\":[]}") }
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[{\"action\":\"shell\",\"count\":1}]}") }
        assertEquals(1000,LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[{\"action\":\"model_next\",\"count\":1000}]}").steps.single().count)
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[{\"action\":\"ai_plus\",\"count\":0}]}") }
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[{\"action\":\"ai_plus\",\"count\":1.5}]}") }
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[],\"extra\":${"[".repeat(18)}0${"]".repeat(18)}}") }
    }

    @Test fun observeAgainMustBeBooleanAndRoundTrips() {
        val plan=LiveAgent.strictPlan("{\"reply\":\"检查画面\",\"steps\":[{\"action\":\"color_gray\",\"count\":1}],\"observe_again\":true}")
        assertTrue(plan.observeAgain)
        assertTrue(LiveAgent.validatePlan(plan.json()).observeAgain)
        assertFails { LiveAgent.strictPlan("{\"reply\":\"x\",\"steps\":[],\"observe_again\":\"true\"}") }
    }

    @Test fun offlineRulesStateTheyAreNotLlmAndRejectAbsoluteTargets() {
        val p=LiveAgent.offlinePlan("请增加 AI 强度 10% 并切换到灰度")
        assertTrue(p.reply.contains("不是 LLM")); assertEquals(listOf("ai_plus","color_gray"),p.steps.map { it.action }); assertEquals(2,p.steps[0].count)
        val verbFirst=LiveAgent.offlinePlan("增加 AI 强度 5%")
        assertEquals(listOf("ai_plus"),verbFirst.steps.map { it.action })
        val absolute=LiveAgent.offlinePlan("把 AI 强度设为 40%")
        assertTrue(absolute.steps.isEmpty()); assertTrue(absolute.reply.contains("未执行"))
        val unsupported=LiveAgent.offlinePlan("帮我写文件")
        assertTrue(unsupported.steps.isEmpty()); assertTrue(unsupported.reply.contains("未执行"))
    }

    @Test fun catalogMatchesOnScreenNamesAndIncludesIdentityPosition() {
        assertEquals(29,LiveAgent.styleCatalog.size)
        assertEquals(29,LiveAgent.styleScreenNames.size)
        assertEquals(13,LiveAgent.lutCatalog.size)
        assertTrue(LiveAgent.knowledge.contains("VANGOGH/梵高星空"))
        assertTrue(LiveAgent.knowledge.contains("IDENTITY/原始"))
        assertTrue(LiveAgent.knowledge.contains("INVERT/负片"))
        assertEquals(2,LiveAgent.actionIds["open_menu"])
    }

    @Test fun nativeToolCallsAreTypedAndRemainAvailableToTheAgent() {
        val definitions=LiveAgent.agentTools()
        val names=(0 until definitions.length()).map { definitions.getJSONObject(it).getJSONObject("function").getString("name") }.toSet()
        assertTrue(names.containsAll(setOf("inspect_app","network_status","observe_screen","reconnect_board",
            "set_receive_session","control_action","set_parameter","check_device_receipt","read_diagnostics")))
        assertFalse(names.contains("set_wipe_position"))
        val call=JSONObject().put("id","call_1").put("type","function").put("function",JSONObject()
            .put("name","control_action").put("arguments","{\"action\":\"model_next\",\"count\":2}"))
        val choice=JSONObject().put("finish_reason","tool_calls").put("message",JSONObject().put("role","assistant")
            .put("content",JSONObject.NULL).put("reasoning_content","keep this for the next tool turn")
            .put("tool_calls",org.json.JSONArray().put(call)))
        val turn=LiveAgent.parseAgentTurn(choice)
        assertEquals("model_next",turn.calls.single().arguments.getString("action"))
        assertEquals("keep this for the next tool turn",turn.assistantMessage.getString("reasoning_content"))
        assertFails { LiveAgent.parseAgentTurn(JSONObject().put("finish_reason","tool_calls").put("message",JSONObject()
            .put("tool_calls",org.json.JSONArray().put(JSONObject().put("id","x").put("type","function")
                .put("function",JSONObject().put("name","exec_shell").put("arguments","{}")))))) }
    }

    @Test fun deepSeekAbsoluteTargetIsRejectedBeforeOpeningInternet() {
        var opened=false
        try { LiveAgent.deepSeekPlan("把 AI 强度调到 50%","secret","deepseek-chat") { opened=true; throw AssertionError("network must not be opened") }; fail("must reject absolute target") }
        catch(_:LiveAgent.AgentFailure) { }
        assertFalse(opened)
    }

    @Test fun deepSeekUsesFixedEndpointDisablesRedirectsAndReleasesNetworkLease() {
        val content=JSONObject().put("reply","ok").put("steps",org.json.JSONArray()).toString()
        val payload=JSONObject().put("choices",org.json.JSONArray().put(JSONObject()
            .put("finish_reason","stop").put("message",JSONObject().put("content",content)))).toString()
        val requestBody=ByteArrayOutputStream()
        val connection=object:HttpURLConnection(URL(LiveAgent.endpoint)) {
            override fun connect() {}
            override fun disconnect() {}
            override fun usingProxy()=false
            override fun getOutputStream()=requestBody
            override fun getInputStream()=ByteArrayInputStream(payload.toByteArray(Charsets.UTF_8))
            override fun getResponseCode()=200
        }
        var released=false
        val plan=LiveAgent.deepSeekPlan("请计划","secret-key","deepseek-flash",image=byteArrayOf(1,2,3)) { url ->
            assertEquals(LiveAgent.endpoint,url.toString())
            LiveAgent.ConnectionLease(connection) { released=true }
        }
        assertTrue(plan.steps.isEmpty())
        val request=JSONObject(requestBody.toString("UTF-8"))
        assertEquals("deepseek-flash",request.getString("model"))
        assertEquals("enabled",request.getJSONObject("thinking").getString("type"))
        assertFalse(request.has("max_tokens"))
        assertEquals("data:image/jpeg;base64,AQID",request.getJSONArray("messages").getJSONObject(1)
            .getJSONArray("content").getJSONObject(1).getJSONObject("image_url").getString("url"))
        assertFalse(connection.instanceFollowRedirects)
        assertEquals("Bearer secret-key",connection.getRequestProperty("Authorization"))
        assertTrue(released)
    }

    @Test fun sceneColorsUseDistinctEightLevelBucketsAndRenderSchema() {
        val stats=SceneStats.analyze(intArrayOf(0xffe00000.toInt(),0xff00e000.toInt(),0xff0000e0.toInt()),3,1)
        assertEquals(3,stats.dominant.size)
        val colors=SceneStats.json(stats).getJSONArray("dominant_colors")
        assertEquals(3,colors.length())
        for(i in 0 until colors.length()) {
            val rgb=colors.getJSONObject(i).getJSONArray("rgb")
            for(j in 0..2) assertTrue(rgb.getInt(j) in 0..255)
        }
    }

    @Test fun manualActionValidationUsesSameAllowlistAndExactIntegers() {
        val valid=LiveAgent.validatePlan(JSONObject().put("reply","manual").put("steps",org.json.JSONArray()
            .put(JSONObject().put("action","model_next").put("count",1))))
        assertEquals("model_next",valid.steps.single().action)
        assertFails { LiveAgent.validatePlan(JSONObject().put("reply","x").put("steps",org.json.JSONArray()
            .put(JSONObject().put("action","model_next").put("count",1.5)))) }
    }

    @Test fun bridgeStagesUseExpectedLittleEndianWordsAndTokenWrap() {
        assertEquals(listOf(0x0180 to 0x1001L, 0x0184 to 0x00000002L), ACommandProtocol.stages(0x10, byteArrayOf(2)))
        assertEquals(listOf(0x0180 to 0x2506L, 0x0184 to 0x04030201L, 0x0188 to 0x00000605L),
            ACommandProtocol.stages(0x25, byteArrayOf(1,2,3,4,5,6)))
        assertEquals(1L,ACommandProtocol.nextToken(0xffffffffL))
        assertThrows(IllegalArgumentException::class.java) { ACommandProtocol.stages(0x10,ByteArray(55)) }
    }

    @Test fun controlWriteAndReplyMatchSequenceRegisterAndOperation() {
        val request=ControlProtocol.write(0x1234,0x01BC,0x89abcdefL)
        assertEquals("43540101123401bc89abcdef",request.joinToString("") { "%02x".format(it) })
        val ack=request.clone(); ack[3]=2
        assertEquals(ControlProtocol.Reply(2,0x89abcdefL),ControlProtocol.reply(ack,12,0x1234,0x01BC))
        assertNull(ControlProtocol.reply(ack,12,0x1235,0x01BC))
        assertNull(ControlProtocol.reply(ack,12,0x1234,0x01BD))
        ack[3]=3; assertEquals(3,ControlProtocol.reply(ack,12,0x1234,0x01BC)?.op)
    }

    @Test fun commandGateCanBeReleasedByAgentWorkerThreadAndStillSerializesManualCommands() {
        val gate=LiveAgent.CommandGate()
        assertTrue(gate.tryAcquire()) // HTTP request reserves before enqueueing Agent work.
        assertFalse(gate.tryAcquire()) // Manual action cannot overlap.
        val done=CountDownLatch(1)
        val worker=Thread { gate.release(); done.countDown() }
        worker.start()
        assertTrue("worker did not release cross-thread reservation",done.await(2,TimeUnit.SECONDS))
        worker.join(2000)
        assertTrue(gate.tryAcquire()) // Gate is reusable after the real worker thread exits.
        gate.release()
    }

    @Test fun agentPlanWatchdogAndUiTimeoutMessagesKeepExecutionOutcomeUnknown() {
        assertTrue(LocalHttpServer.agentPlanWatchdogSeconds >= 60)
        val asset=sequenceOf(File("src/main/assets/index.html"),File("app/src/main/assets/index.html"),
            File("../app/src/main/assets/index.html"),File(System.getProperty("user.dir")+"/app/src/main/assets/index.html"),
            File(System.getProperty("user.dir")+"/apk/app/src/main/assets/index.html"))
            .firstOrNull { it.isFile }
        assertNotNull("Agent UI asset not found; user.dir="+System.getProperty("user.dir"),asset)
        val html=asset!!.readText()
        assertTrue(html.contains("状态暂不可读，继续等待"))
        assertTrue(html.contains("设备确认接收"))
        assertTrue(html.contains("未完成"))
        assertTrue(html.contains("/api/agent/cancel"))
    }

    @Test fun visionMessageFormatUsesContentArray() {
        val plain=LiveAgent.buildMessages("sys","看画面",null,null)
        assertEquals(2,plain.length()); assertTrue(plain.getJSONObject(1).getString("content").contains("看画面"))
        val withImage=LiveAgent.buildMessages("sys","看画面",byteArrayOf(1,2,3,4),"画面偏暗")
        val content=withImage.getJSONObject(1).getJSONArray("content")
        assertEquals("text",content.getJSONObject(0).getString("type"))
        assertEquals("image_url",content.getJSONObject(1).getString("type"))
        assertTrue(content.getJSONObject(1).getJSONObject("image_url").getString("url").startsWith("data:image/jpeg;base64,"))
        assertTrue(withImage.getJSONObject(0).getString("content").isNotBlank())
    }

    @Test fun offlineRecipesMapToDeterministicModeActions() {
        val neon=LiveAgent.offlinePlan("来点赛博霓虹的感觉")
        assertEquals(listOf("color_gray"),neon.steps.map{it.action})
        assertTrue(neon.reply.contains("赛博霓虹")); assertTrue(neon.reply.contains("不是 LLM"))
        val warm=LiveAgent.offlinePlan("暖调胶片")
        assertEquals(listOf("color_curve"),warm.steps.map{it.action})
        val cyan=LiveAgent.offlinePlan("青版印相")
        assertEquals(listOf("color_gray"),cyan.steps.map{it.action})
    }

    @Test fun sceneRecommendationFollowsStats() {
        val hist=List(16){0.0625}
        val dark=LiveAgent.recommendFromScene(SceneStats.Stats(60,30,80,-0.3,listOf(listOf(10,20,30,50)),hist))
        assertEquals("color_gray",dark.steps[0].action); assertTrue(dark.reply.contains("落日熔金"))
        val cold=LiveAgent.recommendFromScene(SceneStats.Stats(120,40,80,-0.3,emptyList(),hist))
        assertEquals("color_curve",cold.steps[0].action); assertTrue(cold.reply.contains("暖调胶片"))
        val dull=LiveAgent.recommendFromScene(SceneStats.Stats(120,40,10,0.0,emptyList(),hist))
        assertTrue(dull.reply.contains("霓虹"))
        val vivid=LiveAgent.recommendFromScene(SceneStats.Stats(120,40,200,0.0,emptyList(),hist))
        assertTrue(vivid.reply.contains("银盐"))
    }

    @Test fun sceneStatsAnalyzeAndSummarize() {
        val w=320;val h=180;val px=IntArray(w*h)
        for(y in 0 until h) for(x in 0 until w) px[y*w+x]=if(y<h/2) 0xFF102030.toInt() else 0xFFE0A040.toInt()
        val s=SceneStats.analyze(px,w,h)
        assertTrue(s.warmth>0.08); assertTrue(s.saturationMean>24)
        val summary=SceneStats.summary(s)
        assertTrue(summary.contains("主色")); assertTrue(summary.contains("画面"))
    }

    @Test fun newWhitelistActionsAreAccepted() {
        val p = LiveAgent.strictPlan("{\"reply\":\"ok\",\"steps\":[{\"action\":\"keep_toggle\",\"count\":1},{\"action\":\"out_plus\",\"count\":2},{\"action\":\"out_minus\",\"count\":1}]}")
        assertEquals(listOf("keep_toggle","out_plus","out_minus"), p.steps.map{it.action})
    }

    @Test fun offlineRecognizesKeepColorAndStyles() {
        val keep = LiveAgent.offlinePlan("保留颜色")
        assertTrue(keep.steps.map{it.action}.contains("keep_toggle"))
        val style = LiveAgent.offlinePlan("我想看赛博朋克风格")
        assertTrue(style.reply.contains("相对") || style.reply.contains("模型") || style.steps.isNotEmpty())
    }

    private fun assertFails(block:()->Unit) { try { block(); fail("expected validation failure") } catch(_:LiveAgent.AgentFailure) { } }
    @Test fun agentContextAllowsExactLimitAndRejectsOneCharacterOver() {
        val messages=JSONArray().put(JSONObject().put("role","user").put("content",""))
        val tools=LiveAgent.agentTools()
        val overhead=LiveAgent.agentContextCharacters(messages,tools)
        messages.getJSONObject(0).put("content","中".repeat(LiveAgent.maxContextCharacters-overhead))
        LiveAgent.validateAgentContext(messages,tools)
        messages.getJSONObject(0).put("content",messages.getJSONObject(0).getString("content")+"中")
        var opened=false
        try {
            LiveAgent.deepSeekAgentTurn(messages,"test-key","deepseek-flash") {
                opened=true;throw AssertionError("Oversized context must not reach network")
            }
            fail("Oversized context should fail")
        } catch(e:LiveAgent.AgentFailure) { assertTrue(e.message!!.contains("500,000")) }
        assertFalse(opened)
        assertEquals(LiveAgent.maxContextCharacters+1,LiveAgent.agentContextCharacters(messages,tools))
    }

    @Test fun agentContextCountsReasoningAndToolsButExcludesImagePayload() {
        val messages=JSONArray().put(JSONObject().put("role","assistant").put("content","😀"))
        val tools=JSONArray()
        val initial=LiveAgent.agentContextCharacters(messages,tools)
        messages.getJSONObject(0).put("content","中")
        assertEquals(initial,LiveAgent.agentContextCharacters(messages,tools))
        messages.getJSONObject(0).put("reasoning_content","reasoning")
        assertTrue(LiveAgent.agentContextCharacters(messages,tools)>initial)
        messages.put(JSONObject().put("role","user").put("content",JSONArray().put(JSONObject()
            .put("type","image_url").put("image_url",JSONObject().put("url","small")))))
        val withImage=LiveAgent.agentContextCharacters(messages,tools)
        messages.getJSONObject(1).getJSONArray("content").getJSONObject(0).getJSONObject("image_url")
            .put("url","x".repeat(600_000))
        assertEquals(withImage,LiveAgent.agentContextCharacters(messages,tools))
        assertTrue(LiveAgent.agentContextCharacters(messages,LiveAgent.agentTools())>withImage)
    }
}
