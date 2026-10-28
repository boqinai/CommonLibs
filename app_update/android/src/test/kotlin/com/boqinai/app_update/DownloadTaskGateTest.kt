package com.boqinai.app_update

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

fun main() {
    timeoutBeatsCompletion()
    completionBeatsTimeout()
    concurrentRaceHasOneWinner()
    otherTerminalsLoseAfterWin()
    commitFailureDoesNotClaimSuccess()
    timeoutBeforeCommitRollsBack()
    timeoutDuringCommitRollsBack()
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

private fun commitFailureDoesNotClaimSuccess() {
    val gate = DownloadTaskGate()
    var rolledBack = false
    try {
        gate.tryCommitSuccess(
            commit = { error("disk full") },
            rollback = { rolledBack = true },
        )
        error("commit unexpectedly succeeded")
    } catch (_: IllegalStateException) {
        check(rolledBack)
        check(gate.get() == TaskState.RUNNING)
        check(gate.tryComplete(TaskState.FAILED))
    }
}

private fun timeoutDuringCommitRollsBack() {
    val gate = DownloadTaskGate()
    val entered = CountDownLatch(1)
    val resume = CountDownLatch(1)
    var rolledBack = false
    val worker = Thread {
        val committed = gate.tryCommitSuccess(
            commit = {
                entered.countDown()
                check(resume.await(5, java.util.concurrent.TimeUnit.SECONDS))
            },
            rollback = { rolledBack = true },
        )
        check(!committed)
    }
    worker.start()
    check(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
    check(gate.tryComplete(TaskState.TIMED_OUT))
    resume.countDown()
    worker.join(5_000)
    check(!worker.isAlive)
    check(rolledBack)
    check(gate.get() == TaskState.TIMED_OUT)
}

private fun timeoutBeforeCommitRollsBack() {
    val gate = DownloadTaskGate()
    var committed = false
    var rolledBack = false
    check(gate.tryComplete(TaskState.TIMED_OUT))
    check(!gate.tryCommitSuccess(
        commit = { committed = true },
        rollback = { rolledBack = true },
    ))
    check(!committed)
    check(rolledBack)
}
