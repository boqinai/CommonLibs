package com.boqinai.fusionauth

import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

fun main() {
    sdkInitThrowReturnsStartFailed()
    staleSessionCallbacksAreIgnored()
    pluginLaunchesThroughController()
    concurrentLaunchesOnlyOwnerMutatesSession()
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

/**
 * Several launches at once: one owns the attempt. The others return busy
 * while that owner is inside startSdk, and must not reset the gate or tear
 * down the SDK. The owner's session still resolves.
 */
private fun concurrentLaunchesOnlyOwnerMutatesSession() {
    val threads = 4
    repeat(30) { round ->
        val scene = FusionSceneController()
        val started = AtomicInteger(0)
        val destroyed = AtomicInteger(0)
        val busy = AtomicInteger(0)
        val winnerEntered = CountDownLatch(1)
        val losersFinished = CountDownLatch(threads - 1)
        val releaseWinner = CountDownLatch(1)
        val finished = CountDownLatch(threads)
        val sessions = Collections.synchronizedList(mutableListOf<Long>())
        val results = Collections.synchronizedList(mutableListOf<FusionTerminal>())
        val start = CountDownLatch(1)
        repeat(threads) {
            Thread {
                try {
                    start.await()
                    val rejected = scene.launch(
                        onResult = { results.add(it) },
                        destroySdk = { destroyed.incrementAndGet() },
                        startSdk = { session ->
                            if (started.incrementAndGet() == 1) {
                                sessions.add(session)
                                winnerEntered.countDown()
                                releaseWinner.await(5, TimeUnit.SECONDS)
                            }
                        },
                    )
                    if (rejected == "busy") {
                        busy.incrementAndGet()
                        losersFinished.countDown()
                    }
                } finally {
                    finished.countDown()
                }
            }.start()
        }
        start.countDown()
        check(winnerEntered.await(5, TimeUnit.SECONDS)) { "round $round winner did not start" }
        check(losersFinished.await(5, TimeUnit.SECONDS)) {
            "round $round losers started=${started.get()} busy=${busy.get()} destroyed=${destroyed.get()}"
        }
        check(started.get() == 1) { "round $round started=${started.get()}" }
        check(busy.get() == threads - 1) { "round $round busy=${busy.get()}" }
        check(destroyed.get() == 1) { "round $round loser tore down sdk: ${destroyed.get()}" }
        val session = sessions.single()
        check(scene.isCurrent(session))
        scene.resolve(session, "verify-token", "ok", "done")
        check(results.size == 1) { "round $round results=$results" }
        check(results.single().code == "ok")
        check(results.single().verifyToken == "verify-token")
        releaseWinner.countDown()
        check(finished.await(5, TimeUnit.SECONDS)) { "round $round threads hung" }
        var relaunched = 0L
        val again = scene.launch(
            onResult = {},
            destroySdk = {},
            startSdk = { relaunched = it },
        )
        check(again == null) { "round $round relaunch after the owner finished returned $again" }
        check(relaunched != 0L && scene.isCurrent(relaunched))
    }
}
