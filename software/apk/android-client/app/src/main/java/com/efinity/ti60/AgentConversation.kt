package com.efinity.ti60

import org.json.JSONArray
import org.json.JSONObject

/** Persistent transcript for the Agent tool loop and visible chat. */
internal class AgentConversation private constructor(
    val messages: JSONArray,
    val visible: JSONArray
) {
    constructor() : this(JSONArray(), JSONArray())

    fun addUser(text: String) {
        repairDanglingToolCalls()
        messages.put(JSONObject().put("role", "user").put("content", text))
        addVisible("user", text)
    }

    fun addAssistant(message: JSONObject) {
        // Tool-call messages (including reasoning_content required by DeepSeek) must
        // be replayed exactly on the next model request.
        messages.put(JSONObject(message.toString()))
    }

    fun addToolResult(callId: String, result: String) {
        messages.put(JSONObject().put("role", "tool").put("tool_call_id", callId).put("content", result))
    }

    fun addAssistantFinal(text: String) {
        messages.put(JSONObject().put("role", "assistant").put("content", text))
        addVisible("assistant", text)
    }

    /** Close incomplete tool batches left behind by process death before the next user turn. */
    fun repairDanglingToolCalls() {
        val repaired=JSONArray()
        var i=0
        while(i<messages.length()) {
            val m=messages.optJSONObject(i)
            if(m==null) { i++; continue }
            repaired.put(m)
            val calls=m.optJSONArray("tool_calls")
            if(m.optString("role")=="assistant" && calls!=null && calls.length()>0) {
                val required=(0 until calls.length()).mapNotNull { calls.optJSONObject(it)?.optString("id")?.takeIf(String::isNotBlank) }.toSet()
                val found=mutableSetOf<String>(); var j=i+1
                while(j<messages.length() && messages.optJSONObject(j)?.optString("role")=="tool") {
                    val toolMessage=messages.optJSONObject(j)!!
                    repaired.put(toolMessage); found += toolMessage.optString("tool_call_id"); j++
                }
                for(id in required-found) repaired.put(JSONObject().put("role","tool").put("tool_call_id",id)
                    .put("content","{\"ok\":false,\"state\":\"interrupted\",\"message\":\"App 上次在工具执行中退出；请先检查设备当前状态\"}"))
                i=j
            } else i++
        }
        while(messages.length()>0) messages.remove(0)
        for(index in 0 until repaired.length()) messages.put(repaired.get(index))
    }

    fun addVisible(role: String, text: String) {
        visible.put(JSONObject().put("role", role).put("text", text).put("time", System.currentTimeMillis()))
    }

    fun apiMessages(): JSONArray = JSONArray(messages.toString())
    fun visibleMessages(): JSONArray = JSONArray(visible.toString())

    fun toJson(): JSONObject = JSONObject()
        .put("messages", messages)
        .put("visible", visible)

    companion object {
        fun fromJson(json: String?): AgentConversation {
            if (json.isNullOrBlank()) return AgentConversation()
            return try {
                val root = JSONObject(json)
                AgentConversation(
                    root.optJSONArray("messages")?.let { JSONArray(it.toString()) } ?: JSONArray(),
                    root.optJSONArray("visible")?.let { JSONArray(it.toString()) } ?: JSONArray()
                )
            } catch (_: Exception) {
                AgentConversation()
            }
        }
    }
}
