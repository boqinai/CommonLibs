package com.boqinai.app_update

import java.util.concurrent.atomic.AtomicReference

/**
 * Per-download terminal state. SUCCESS, FAILED, CANCELLED, and TIMED_OUT are
 * reached only by a compare-and-set from RUNNING, so a timeout and the worker
 * cannot both publish a result.
 */
enum class TaskState {
    RUNNING,
    SUCCESS,
    FAILED,
    CANCELLED,
    TIMED_OUT,
}

class DownloadTaskGate {
    private val state = AtomicReference(TaskState.RUNNING)

    fun get(): TaskState = state.get()

    fun tryComplete(next: TaskState): Boolean {
        check(next != TaskState.RUNNING) { "terminal state required" }
        return state.compareAndSet(TaskState.RUNNING, next)
    }

    /**
     * Finalizes the downloaded file before publishing SUCCESS. A timeout may
     * win while [commit] is running; in that case the committed file is rolled
     * back and SUCCESS is not exposed. A failed commit leaves the gate running
     * so the caller can publish FAILED.
     */
    fun tryCommitSuccess(commit: () -> Unit, rollback: () -> Unit): Boolean {
        if (state.get() != TaskState.RUNNING) {
            rollback()
            return false
        }
        try {
            commit()
        } catch (error: Throwable) {
            rollback()
            throw error
        }
        if (state.compareAndSet(TaskState.RUNNING, TaskState.SUCCESS)) return true
        rollback()
        return false
    }
}
