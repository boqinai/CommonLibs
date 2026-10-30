package com.boqinai.fusionauth

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

fun main() {
    sdkInitThrowReturnsStartFailed()
    sdkResultsRunOnTheResolvingThreadDuringInitialization()
    staleSessionCallbacksAreIgnored()
    retriesNeverRearmAnOldCallbackGate()
    concurrentLaunchesOnlyOwnerMutatesSession()
    releaseWaitsForLaunchInitialization()
    failureCallbackIsOutsideLockAndRetryIsBusy()
    releaseCallbackRunsOutsideLock()
    launchAndReleaseAssertMainThread()
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

/** A concurrent release cannot invalidate the session midway through launch. */
private fun releaseWaitsForLaunchInitialization() {
    val scene = FusionSceneController()
    val launchEntered = CountDownLatch(1)
    val allowLaunchReturn = CountDownLatch(1)
    val launchFinished = CountDownLatch(1)
    val releaseFinished = CountDownLatch(1)
    val events = Collections.synchronizedList(mutableListOf<String>())
    var session = 0L
    var terminal: FusionTerminal? = null

    Thread {
        scene.launch(
            onResult = { terminal = it },
            destroySdk = { events.add("destroy") },
            startSdk = {
                session = it
                events.add("start")
                launchEntered.countDown()
                check(allowLaunchReturn.await(5, TimeUnit.SECONDS))
                events.add("start-return")
            },
        )
        launchFinished.countDown()
    }.start()
    check(launchEntered.await(5, TimeUnit.SECONDS))

    Thread {
        scene.release({ events.add("release-destroy") }, "cancelled", "detached")
        events.add("release-return")
        releaseFinished.countDown()
    }.start()
    check(!releaseFinished.await(100, TimeUnit.MILLISECONDS)) { "release crossed an active launch" }
    check(scene.isCurrent(session))

    allowLaunchReturn.countDown()
    check(launchFinished.await(5, TimeUnit.SECONDS))
    check(releaseFinished.await(5, TimeUnit.SECONDS))
    check(terminal?.code == "cancelled")
    check(terminal?.message == "detached")
    check(!scene.isCurrent(session))
    check(events.indexOf("start-return") < events.indexOf("release-destroy")) { events }
}

/**
 * The start_failed callback runs after the lifecycle lock is released and
 * before launch returns. The launch claim is still held, so a nested launch
 * returns busy and does not start a second session. A launch once the outer
 * call has returned proceeds.
 */
private fun failureCallbackIsOutsideLockAndRetryIsBusy() {
    val scene = FusionSceneController()
    var nested: String? = "missing"
    var nestedStarts = 0
    val probeEntered = CountDownLatch(1)
    val probeFinished = CountDownLatch(1)
    val rejected = scene.launch(
        onResult = {
            nested = scene.launch(
                onResult = {},
                destroySdk = {},
                startSdk = { nestedStarts += 1 },
            )
            Thread {
                probeEntered.countDown()
                scene.release({}, "cancelled", "probe")
                probeFinished.countDown()
            }.start()
            check(probeEntered.await(5, TimeUnit.SECONDS)) { "probe did not start" }
            check(probeFinished.await(1, TimeUnit.SECONDS)) {
                "failure callback ran while the lifecycle lock was held"
            }
        },
        destroySdk = {},
        startSdk = { throw IllegalStateException("init failed") },
    )
    check(rejected == null)
    check(nested == "busy") { "reentrant launch returned $nested" }
    check(nestedStarts == 0) { "busy launch started the SDK" }
    var retried = 0L
    val again = scene.launch(
        onResult = {},
        destroySdk = {},
        startSdk = { retried = it },
    )
    check(again == null) { "launch after the owner returned was $again" }
    check(retried != 0L && scene.isCurrent(retried))
}

/** release delivers onResult only after it has dropped the lifecycle lock. */
private fun releaseCallbackRunsOutsideLock() {
    val scene = FusionSceneController()
    val probeEntered = CountDownLatch(1)
    val probeFinished = CountDownLatch(1)
    var outside = false
    val rejected = scene.launch(
        onResult = {
            Thread {
                probeEntered.countDown()
                scene.release({}, "cancelled", "probe")
                probeFinished.countDown()
            }.start()
            check(probeEntered.await(5, TimeUnit.SECONDS))
            outside = probeFinished.await(1, TimeUnit.SECONDS)
        },
        destroySdk = {},
        startSdk = {},
    )
    check(rejected == null)
    scene.release({}, "cancelled", "done")
    check(outside) { "release callback ran while the lifecycle lock was held" }
    check(!scene.hasPending())
}

private fun launchAndReleaseAssertMainThread() {
    var main = true
    val scene = FusionSceneController(isMainThread = { main })
    var session = 0L
    val started = scene.launch(
        onResult = {},
        destroySdk = {},
        startSdk = { session = it },
    )
    check(started == null && session != 0L && scene.isCurrent(session))

    main = false
    val releaseError = catchMainThread {
        scene.release({}, "cancelled", "off-main")
    }
    check(releaseError != null) { "off-main release was accepted" }
    check(scene.isCurrent(session)) { "off-main release changed the session" }
    check(scene.hasPending())

    val launchError = catchMainThread {
        scene.launch(onResult = {}, destroySdk = {}, startSdk = {})
    }
    check(launchError != null) { "off-main launch was accepted" }
    check(scene.isCurrent(session)) { "off-main launch changed the session" }

    main = true
    scene.release({}, "cancelled", "main")
    check(!scene.hasPending())
    check(!scene.isCurrent(session))
    var relaunched = 0L
    val again = scene.launch(
        onResult = {},
        destroySdk = {},
        startSdk = { relaunched = it },
    )
    check(again == null && relaunched != 0L && scene.isCurrent(relaunched))
}

private fun catchMainThread(body: () -> Unit): IllegalStateException? {
    try {
        body()
    } catch (error: IllegalStateException) {
        check(error.message?.contains("main thread") == true) { error.message ?: "" }
        return error
    }
    return null
}

private fun retriesNeverRearmAnOldCallbackGate() {
    val originalGate = FusionStartGate()
    val scene = FusionSceneController(originalGate)
    var oldSession = 0L
    val results = mutableListOf<FusionTerminal>()
    scene.launch(results::add, {}) { oldSession = it }
    scene.release({}, "cancelled", "")
    var newSession = 0L
    scene.launch(results::add, {}) { newSession = it }
    check(originalGate.current()?.code == "cancelled") { "Retry reset a gate still referenced by the old SDK" }
    scene.resolve(oldSession, "old-token", "ok", "")
    check(scene.hasPending())
    scene.resolve(newSession, "new-token", "ok", "")
    check(results.map { it.verifyToken } == listOf(null, "new-token"))
}

private fun sdkResultsRunOnTheResolvingThreadDuringInitialization() {
    val scene = FusionSceneController()
    val resolved = CountDownLatch(1)
    val callbackThread = java.util.concurrent.atomic.AtomicReference<Thread?>()
    var sdkThread: Thread? = null
    var terminal: FusionTerminal? = null
    scene.launch(
        onResult = { terminal = it; callbackThread.set(Thread.currentThread()) },
        destroySdk = {},
        startSdk = { session ->
            sdkThread = Thread {
                scene.resolve(session, "authorized", "ok", "")
                resolved.countDown()
            }.also { it.start() }
            check(resolved.await(5, TimeUnit.SECONDS)) { "SDK callback waited for initialization" }
        },
    )
    sdkThread?.join(5_000)
    check(terminal?.verifyToken == "authorized")
    check(callbackThread.get() === sdkThread) { "resolve unexpectedly changed callback threads" }
    check(!scene.hasPending())
}
