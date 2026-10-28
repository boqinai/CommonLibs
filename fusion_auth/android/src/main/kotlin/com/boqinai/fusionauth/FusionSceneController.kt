package com.boqinai.fusionauth

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock

/**
 * Plugin-level fusion start session. SDK init is [launch]'s [startSdk]
 * callback. A throw completes the pending start once, as `start_failed`.
 * A later cancel cannot replace that terminal status. Callbacks captured
 * with the session id from [launch] are ignored after [release] moves the
 * generation counter.
 *
 * [launch] and [release] run on the platform main thread. [isMainThread]
 * asserts that contract; [FusionAuthPlugin] passes
 * `Looper.myLooper() == Looper.getMainLooper()`. The default predicate is
 * for JVM tests that race [launch] against [release] off the main thread.
 *
 * [startSdk] and [destroySdk] run while [lifecycle] is held, so a concurrent
 * [release] waits until initialization finishes before it advances the
 * generation or tears the SDK down. Result callbacks run after that lock is
 * released. [launchOwner] stays claimed until [launch] returns, including
 * while the `start_failed` callback runs, so a nested [launch] from that
 * callback returns "busy". Retry after [launch] returns.
 */
class FusionSceneController(
    private val gate: FusionStartGate = FusionStartGate(),
    private val isMainThread: () -> Boolean = { true },
) {
    private val generation = AtomicLong()
    private val pending = AtomicReference<((FusionTerminal) -> Unit)?>(null)

    /**
     * Launch ownership is independent of [pending] and [gate], so concurrent
     * and same-thread reentrant launches return busy immediately. The lifecycle
     * lock also makes release wait for SDK initialization before it advances
     * the generation or tears down the SDK.
     */
    private val launchOwner = AtomicReference<Any?>(null)
    private val lifecycle = ReentrantLock()

    fun hasPending(): Boolean = pending.get() != null

    fun isCurrent(session: Long): Boolean = session == generation.get()

    /**
     * Starts one scene. Returns "busy" when a start is already pending,
     * another lifecycle operation owns the attempt, or this call is reentered
     * from the result callback before it returns. [destroySdk] runs before
     * the new session and again if init throws. A null return means the SDK
     * call returned or init failed terminally.
     *
     * Must run on the main thread. The result callback runs after the
     * lifecycle lock is released and before this call returns.
     */
    fun launch(
        onResult: (FusionTerminal) -> Unit,
        destroySdk: () -> Unit,
        startSdk: (session: Long) -> Unit,
    ): String? {
        assertMainThread()
        val claim = Any()
        if (!launchOwner.compareAndSet(null, claim)) return "busy"
        var terminal: FusionTerminal? = null
        try {
            lifecycle.lock()
            try {
                if (pending.get() != null) return "busy"
                destroySdk()
                generation.incrementAndGet()
                val session = generation.incrementAndGet()
                gate.reset()
                if (!gate.arm() || !pending.compareAndSet(null, onResult)) {
                    gate.reset()
                    pending.compareAndSet(onResult, null)
                    return "busy"
                }
                try {
                    startSdk(session)
                } catch (error: Throwable) {
                    terminal = completeLocked(
                        destroySdk,
                        "start_failed",
                        error.message ?: error.javaClass.simpleName,
                    )
                }
                return null
            } finally {
                lifecycle.unlock()
            }
        } finally {
            val won = terminal
            try {
                if (won != null) deliver(won)
            } finally {
                launchOwner.compareAndSet(claim, null)
            }
        }
    }

    /**
     * Ends the current session. Must run on the main thread. [destroySdk]
     * runs inside the lifecycle lock. The result callback runs after the
     * lock is released.
     */
    fun release(destroySdk: () -> Unit, code: String, message: String) {
        assertMainThread()
        lifecycle.lock()
        val terminal = try {
            completeLocked(destroySdk, code, message)
        } finally {
            lifecycle.unlock()
        }
        if (terminal != null) deliver(terminal)
    }

    fun resolve(session: Long, token: String?, code: String, message: String) {
        if (!isCurrent(session)) return
        val won = gate.complete(code, message, token) ?: return
        deliver(won)
    }

    /** Caller holds [lifecycle]. Does not invoke the result callback. */
    private fun completeLocked(destroySdk: () -> Unit, code: String, message: String): FusionTerminal? {
        val won = gate.complete(code, message, null)
        generation.incrementAndGet()
        destroySdk()
        return won
    }

    private fun deliver(terminal: FusionTerminal) {
        val callback = pending.getAndSet(null) ?: return
        callback(terminal)
    }

    private fun assertMainThread() {
        check(isMainThread()) {
            "FusionSceneController launch and release must run on the main thread"
        }
    }
}
