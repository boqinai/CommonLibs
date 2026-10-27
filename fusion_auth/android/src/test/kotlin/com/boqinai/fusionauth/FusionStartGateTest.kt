package com.boqinai.fusionauth

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

fun main() {
    sdkInitExceptionReturnsStartFailedNotCancelled()
    concurrentCompleteOnce()
    println("fusion start gate ok")
}

/**
 * Mirrors FusionAuthPlugin's init catch: release(start_failed) once.
 * The old bug then called release(), which completed the same request as cancelled.
 */
private fun sdkInitExceptionReturnsStartFailedNotCancelled() {
    val gate = FusionStartGate()
    check(gate.arm())
    val init = IllegalStateException("sdk init exploded")
    val won = gate.complete("start_failed", init.message ?: init.javaClass.simpleName, null)
    check(won != null)
    check(won.code == "start_failed") { won.code }
    check(won.message == "sdk init exploded")
    check(gate.complete("cancelled", "", null) == null)
    check(gate.current()?.code == "start_failed")
}

private fun concurrentCompleteOnce() {
    repeat(50) {
        val gate = FusionStartGate()
        check(gate.arm())
        val wins = AtomicInteger(0)
        val codes = java.util.Collections.synchronizedList(mutableListOf<String>())
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        for (code in listOf("start_failed", "cancelled")) {
            Thread {
                start.await()
                val won = gate.complete(code, code, null)
                if (won != null) {
                    wins.incrementAndGet()
                    codes.add(won.code)
                }
                done.countDown()
            }.start()
        }
        start.countDown()
        check(done.await(5, java.util.concurrent.TimeUnit.SECONDS))
        check(wins.get() == 1) { "wins=${wins.get()} codes=$codes" }
        check(codes.single() == gate.current()?.code)
    }
}
