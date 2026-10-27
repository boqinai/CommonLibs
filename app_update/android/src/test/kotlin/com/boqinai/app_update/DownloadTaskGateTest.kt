package com.boqinai.app_update

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

fun main() {
    timeoutBeatsCompletion()
    completionBeatsTimeout()
    concurrentRaceHasOneWinner()
    otherTerminalsLoseAfterWin()
    println("download task gate ok")
}

private fun timeoutBeatsCompletion() {
    val gate = DownloadTaskGate()
    check(gate.tryComplete(TaskState.TIMED_OUT))
    check(!gate.tryComplete(TaskState.SUCCESS))
    check(gate.get() == TaskState.TIMED_OUT)
}

private fun completionBeatsTimeout() {
    val gate = DownloadTaskGate()
    check(gate.tryComplete(TaskState.SUCCESS))
    check(!gate.tryComplete(TaskState.TIMED_OUT))
    check(gate.get() == TaskState.SUCCESS)
}

private fun concurrentRaceHasOneWinner() {
    repeat(100) {
        val gate = DownloadTaskGate()
        val wins = AtomicInteger(0)
        val winner = AtomicReference<TaskState?>(null)
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        for (terminal in listOf(TaskState.SUCCESS, TaskState.TIMED_OUT)) {
            Thread {
                start.await()
                if (gate.tryComplete(terminal)) {
                    wins.incrementAndGet()
                    winner.set(terminal)
                }
                done.countDown()
            }.start()
        }
        start.countDown()
        check(done.await(5, java.util.concurrent.TimeUnit.SECONDS))
        check(wins.get() == 1) { "wins=${wins.get()}" }
        check(gate.get() == winner.get())
    }
}

private fun otherTerminalsLoseAfterWin() {
    val gate = DownloadTaskGate()
    check(gate.tryComplete(TaskState.TIMED_OUT))
    check(!gate.tryComplete(TaskState.FAILED))
    check(!gate.tryComplete(TaskState.CANCELLED))
    check(!gate.tryComplete(TaskState.SUCCESS))
    check(gate.get() == TaskState.TIMED_OUT)
}
