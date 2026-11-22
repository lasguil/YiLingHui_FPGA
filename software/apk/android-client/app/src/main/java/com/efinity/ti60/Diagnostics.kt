package com.efinity.ti60

import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Small in-memory connection log: no passwords or API keys. */
object Diagnostics {
    private const val TAG = "Ti60Net"
    private const val MAX_LINES = 600
    private val lines = ArrayDeque<String>()
    private val lock = Any()
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    fun log(message: String) {
        val line = stamp.format(Date()) + "  " + message
        synchronized(lock) {
            if (lines.size >= MAX_LINES) lines.removeFirst()
            lines.addLast(line)
        }
        Log.i(TAG, message)
    }

    fun dump(): String = synchronized(lock) { lines.joinToString("\n") }

    fun clear() {
        synchronized(lock) { lines.clear() }
    }
}
