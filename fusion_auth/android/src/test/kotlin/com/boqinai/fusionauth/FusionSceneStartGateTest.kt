package com.boqinai.fusionauth

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

fun main() {
    val gate = FusionSceneStartGate()
    val queue = mutableListOf<() -> Unit>()
    var started = 0
    var current = true
    check(started == 0)
    repeat(4) { gate.authenticated({ current }, { queue.add(it) }, { started++ }) }
    check(started == 0) { "Must wait until the SDK callback returns" }
    check(queue.size == 1) { "Token renewal must not queue duplicate scenes" }
    queue.removeAt(0)()
    check(started == 1)
    gate.authenticated({ current }, { queue.add(it) }, { started++ })
    check(queue.isEmpty())
    val cancelled = FusionSceneStartGate()
    cancelled.authenticated({ current }, { queue.add(it) }, { started++ })
    current = false
    queue.removeAt(0)()
    check(started == 1) { "Cancelled sessions must not start their queued scene" }
    val stale = FusionSceneStartGate()
    stale.authenticated({ false }, { queue.add(it) }, { started++ })
    check(queue.isEmpty())
    concurrentAuthenticationQueuesOnce()
    println("fusion authenticated scene start ok")
}

private fun concurrentAuthenticationQueuesOnce() {
    val gate = FusionSceneStartGate()
    val queued = Collections.synchronizedList(mutableListOf<() -> Unit>())
    val ready = CountDownLatch(8)
    val fire = CountDownLatch(1)
    val finished = CountDownLatch(8)
    val starts = AtomicInteger()
    repeat(8) {
        Thread {
            ready.countDown()
            fire.await()
            gate.authenticated({ true }, { queued.add(it) }, { starts.incrementAndGet() })
            finished.countDown()
        }.start()
    }
    ready.await()
    fire.countDown()
    finished.await()
    check(queued.size == 1) { "queued ${queued.size} starts" }
    queued.single()()
    check(starts.get() == 1)
}
