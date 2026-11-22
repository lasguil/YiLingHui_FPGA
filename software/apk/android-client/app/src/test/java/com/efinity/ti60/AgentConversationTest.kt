package com.efinity.ti60

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AgentConversationTest {
    @Test fun persistentTranscriptKeepsToolCallReasoningAndVisibleTurns() {
        val c=AgentConversation()
        c.addUser("切到梵高")
        c.addAssistant(JSONObject().put("role","assistant").put("content",JSONObject.NULL)
            .put("reasoning_content","reasoning needed by provider").put("tool_calls",JSONArray().put(JSONObject()
                .put("id","call-1").put("type","function").put("function",JSONObject().put("name","inspect_app").put("arguments","{}")))))
        c.addToolResult("call-1","{\"ok\":true}")
        c.addAssistantFinal("已完成")
        val restored=AgentConversation.fromJson(c.toJson().toString())
        assertEquals(4,restored.apiMessages().length())
        assertEquals("reasoning needed by provider",restored.apiMessages().getJSONObject(1).getString("reasoning_content"))
        assertEquals("切到梵高",restored.visibleMessages().getJSONObject(0).getString("text"))
        assertEquals("已完成",restored.visibleMessages().getJSONObject(1).getString("text"))
    }

    @Test fun interruptedToolBatchIsClosedBeforeNewConversationTurn() {
        val c=AgentConversation()
        c.addUser("继续")
        c.addAssistant(JSONObject().put("role","assistant").put("content",JSONObject.NULL).put("tool_calls",JSONArray()
            .put(JSONObject().put("id","call-a")).put(JSONObject().put("id","call-b"))))
        c.addToolResult("call-a","{\"ok\":true}")
        c.repairDanglingToolCalls()
        c.addUser("1")
        val m=c.apiMessages()
        assertEquals("call-a",m.getJSONObject(2).getString("tool_call_id"))
        assertEquals("call-b",m.getJSONObject(3).getString("tool_call_id"))
        assertEquals("interrupted",JSONObject(m.getJSONObject(3).getString("content")).getString("state"))
        assertEquals("user",m.getJSONObject(4).getString("role"))
    }

    @Test fun completeHistoryRemainsUncompactedAcrossManyTurns() {
        val c=AgentConversation()
        repeat(50) { i -> c.addUser("request-$i " + "x".repeat(1200)); c.addAssistantFinal("answer-$i " + "y".repeat(1200)) }
        assertEquals(100,c.apiMessages().length())
        assertEquals("request-0 " + "x".repeat(1200),c.apiMessages().getJSONObject(0).getString("content"))
        assertEquals("answer-49 " + "y".repeat(1200),c.apiMessages().getJSONObject(99).getString("content"))
        assertEquals(100,c.visibleMessages().length())
    }
    @Test fun legacySummaryIsIgnoredAndNotPersisted() {
        val old=JSONObject().put("summary","旧摘要").put("messages",JSONArray()
            .put(JSONObject().put("role","user").put("content","保留历史")))
        val restored=AgentConversation.fromJson(old.toString())
        assertFalse(restored.toJson().has("summary"))
        assertEquals("保留历史",restored.apiMessages().getJSONObject(0).getString("content"))
    }
}
