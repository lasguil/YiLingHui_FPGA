package com.efinity.ti60

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkPermissionTest {
    @Test
    fun cellularFallbackDeclaresNetworkChangePermission() {
        // requestNetwork(CELLULAR, ...) needs CHANGE_NETWORK_STATE. Keep this
        // check tied to the source manifest so removing the declaration fails JVM CI.
        val manifestFile = listOf(
            File("src/main/AndroidManifest.xml"),
            File("app/src/main/AndroidManifest.xml"),
        ).firstOrNull { it.isFile }
        assertTrue("Could not locate the Android source manifest", manifestFile != null)
        val manifest = manifestFile!!.readText()
        assertTrue(
            "CELLULAR requestNetwork fallback requires CHANGE_NETWORK_STATE",
            Regex("<uses-permission\\s+android:name=\"android\\.permission\\.CHANGE_NETWORK_STATE\"\\s*/>")
                .containsMatchIn(manifest),
        )
    }
}
