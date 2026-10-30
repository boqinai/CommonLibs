package com.boqinai.fusionauth

private class FakeClock {
    data class Task(val at: Long, val action: () -> Unit, var cancelled: Boolean = false)
    var now = 0L
    val tasks = mutableListOf<Task>()
    fun schedule(action: () -> Unit): () -> Unit {
        val task = Task(now + 15_000, action)
        tasks.add(task)
        return { task.cancelled = true }
    }
    fun advance(milliseconds: Long) {
        now += milliseconds
        val due = tasks.filter { !it.cancelled && it.at <= now }
        due.forEach { it.cancelled = true; it.action() }
    }
}

private class Attempt {
    val clock = FakeClock()
    val watchdog = FusionAuthWatchdog()
    val scene = FusionSceneController()
    val results = mutableListOf<FusionTerminal>()
    var currentSession = 0L
    var destroyed = 0
    fun cleanup() { watchdog.cancel(); destroyed++ }
    fun start() {
        check(scene.launch(results::add, ::cleanup) { session ->
            currentSession = session
            watchdog.arm(clock::schedule) {
                if (scene.isCurrent(session) && scene.hasPending()) {
                    scene.release(::cleanup, "sdk_auth_timeout", "timeout")
                }
            }
        } == null)
    }
}

fun main() {
    val stalled = Attempt()
    stalled.start()
    stalled.clock.advance(14_999)
    check(stalled.results.isEmpty())
    stalled.clock.advance(1)
    check(stalled.results.single().code == "sdk_auth_timeout")
    check(!stalled.scene.hasPending())
    stalled.clock.advance(30_000)
    check(stalled.results.size == 1)
    stalled.start()
    check(stalled.scene.hasPending()) { "Timeout must allow retry" }

    val successful = Attempt()
    successful.start()
    val lateTimeout = successful.clock.tasks.single()
    successful.watchdog.cancel() // The SDK authentication succeeded.
    lateTimeout.action() // Simulate a callback already queued before cancellation.
    check(successful.results.isEmpty()) { "An authenticated authorization page must stay open" }
    successful.scene.resolve(successful.currentSession, "verified", "success", "")
    check(successful.results.single().verifyToken == "verified")

    val cancelled = Attempt()
    cancelled.start()
    val old = cancelled.clock.tasks.single()
    val oldSession = cancelled.currentSession
    cancelled.scene.release(cancelled::cleanup, "cancelled", "")
    cancelled.start()
    old.action()
    cancelled.scene.resolve(oldSession, "old-token", "success", "")
    check(cancelled.results.size == 1) { "An old attempt must not resolve a retry" }
    cancelled.clock.advance(15_000)
    check(cancelled.results.map { it.code } == listOf("cancelled", "sdk_auth_timeout"))

    val failed = Attempt()
    failed.start()
    failed.watchdog.cancel()
    failed.scene.resolve(failed.currentSession, null, "vendor_auth_failed", "")
    failed.scene.release(failed::cleanup, "cancelled", "")
    failed.clock.advance(15_000)
    check(failed.results.single().code == "vendor_auth_failed")
    println("fusion authentication watchdog ok")
}
