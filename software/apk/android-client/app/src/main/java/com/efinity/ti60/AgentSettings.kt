package com.efinity.ti60

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The API key is encrypted with a non-exportable Android Keystore key. */
class AgentSettings(context: Context) {
    private val prefs=context.getSharedPreferences("agent_settings",Context.MODE_PRIVATE)
    private val alias="ti60.agent.api-key.v1"
    private fun secret(): SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias,null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun readKey(): String {
        val encoded=prefs.getString("encrypted_key",null) ?: return ""
        val iv=Base64.decode(prefs.getString("key_iv",null) ?: error("缺少密钥参数"),Base64.NO_WRAP)
        val cipher=Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE,secret(),GCMParameterSpec(128,iv))
        return cipher.doFinal(Base64.decode(encoded,Base64.NO_WRAP)).toString(Charsets.UTF_8)
    }
    fun save(mode:String,model:String,sendImage:Boolean,key:String?) {
        val edit=prefs.edit().putString("mode",mode).putString("model",model).putBoolean("send_image",sendImage)
        if(key!=null) {
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE,secret())
            edit.putString("encrypted_key",Base64.encodeToString(cipher.doFinal(key.toByteArray(Charsets.UTF_8)),Base64.NO_WRAP))
                .putString("key_iv",Base64.encodeToString(cipher.iv,Base64.NO_WRAP))
        }
        check(edit.commit()) { "保存设置失败" }
    }
    internal fun readConversation()=AgentConversation.fromJson(prefs.getString("conversation_v1",null))
    internal fun saveConversation(conversation:AgentConversation) {
        check(prefs.edit().putString("conversation_v1",conversation.toJson().toString()).commit()) { "Agent 对话记忆保存失败" }
    }
    internal fun clearConversation() { check(prefs.edit().remove("conversation_v1").commit()) { "Agent 对话记忆清除失败" } }

    /** Persist board Wi-Fi credentials encrypted with the same app-private Keystore key. */
    fun saveWifi(ssid:String, passphrase:String) {
        val cipher=Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE,secret())
        check(prefs.edit().putString("wifi_ssid",ssid)
            .putString("encrypted_wifi_pass",Base64.encodeToString(cipher.doFinal(passphrase.toByteArray(Charsets.UTF_8)),Base64.NO_WRAP))
            .putString("wifi_pass_iv",Base64.encodeToString(cipher.iv,Base64.NO_WRAP)).commit()) { "Wi-Fi 设置保存失败" }
    }
    fun readWifi():Pair<String,String> {
        val ssid=prefs.getString("wifi_ssid","") ?: ""
        val encoded=prefs.getString("encrypted_wifi_pass",null) ?: return ssid to ""
        val iv=Base64.decode(prefs.getString("wifi_pass_iv",null) ?: error("缺少 Wi-Fi 密钥参数"),Base64.NO_WRAP)
        val cipher=Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE,secret(),GCMParameterSpec(128,iv))
        return ssid to cipher.doFinal(Base64.decode(encoded,Base64.NO_WRAP)).toString(Charsets.UTF_8)
    }
    fun mode()=prefs.getString("mode","offline") ?: "offline"
    fun model()=prefs.getString("model","deepseek-flash") ?: "deepseek-flash"
    fun sendImage()=prefs.getBoolean("send_image",true)
}
