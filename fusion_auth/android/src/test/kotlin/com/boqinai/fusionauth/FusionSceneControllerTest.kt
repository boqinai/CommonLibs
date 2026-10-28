package com.boqinai.fusionauth

import java.io.File

fun main() {
    sdkInitThrowReturnsStartFailed()
    staleSessionCallbacksAreIgnored()
    pluginLaunchesThroughController()
    println("fusion scene controller ok")
}

private fun sdkInitThrowReturnsStartFailed() {
    val scene = FusionSceneController()
    var terminal: FusionTerminal? = null
    var destroyed = 0
    val rejected = scene.launch(
        onResult = { terminal = it },
        destroySdk = { destroyed += 1 },
        startSdk = { throw IllegalStateException("sdk init exploded") },
    )
    check(rejected == null)
    check(terminal?.code == "start_failed") { terminal?.code ?: "" }
    check(terminal?.message == "sdk init exploded")
    check(destroyed >= 1)
    scene.release({}, "cancelled", "")
    check(terminal?.code == "start_failed")
    check(scene.hasPending() == false)
}

private fun staleSessionCallbacksAreIgnored() {
    val scene = FusionSceneController()
    var session = 0L
    var deliveries = 0
    val rejected = scene.launch(
        onResult = { deliveries += 1 },
        destroySdk = {},
        startSdk = { session = it },
    )
    check(rejected == null)
    check(session != 0L)
    check(scene.isCurrent(session))
    scene.release({}, "cancelled", "")
    check(deliveries == 1)
    check(!scene.isCurrent(session))
    scene.resolve(session, "verify-token", "ok", "late")
    check(deliveries == 1)
}

private fun pluginLaunchesThroughController() {
    val src = File("fusion_auth/android/src/main/kotlin/com/boqinai/fusionauth/FusionAuthPlugin.kt").readText()
    check(src.contains("FusionSceneController"))
    check(src.contains("scene.launch"))
    check(src.contains("scene.isCurrent"))
    check(!src.contains("sessionGeneration"))
}
