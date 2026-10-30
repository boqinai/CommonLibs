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
 * generation or tears the SDK down. Initialization-failure and release
 * callbacks run after that lock is released on their main-thread caller. SDK
 * results delivered by resolve run on the resolving thread (possibly during
 * initialization); callers must marshal UI/channel work themselves.
 * [launchOwner] stays claimed until [launch] returns, including
 * while the `start_failed` callback runs, so a nested [launch] from that
 * callback returns "busy". Retry after [launch] returns.
 */
class FusionSceneController(
    gate: FusionStartGate = FusionStartGate(),
    private val isMainThread: () -> Boolean = { true },
) {
    private val generation = AtomicLong()
    private class Attempt(val id: Long, val gate: FusionStartGate, callback: (FusionTerminal) -> Unit) {
        val pending = AtomicReference<((FusionTerminal) -> Unit)?>(callback)
    }
    private data class Delivery(val terminal: FusionTerminal, val callback: (FusionTerminal) -> Unit) {
        fun send() = callback(terminal)
    }
    private val firstGate = AtomicReference<FusionStartGate?>(gate)
    private val attempt = AtomicReference<Attempt?>(null)

    /**
     * Launch ownership is independent of the pending callback and terminal gate, so concurrent
     * and same-thread reentrant launches return busy immediately. The lifecycle
     * lock also makes release wait for SDK initialization before it advances
     * the generation or tears down the SDK.
     */
    private val launchOwner = AtomicReference<Any?>(null)
    private val lifecycle = ReentrantLock()

    fun hasPending(): Boolean = attempt.get()?.pending?.get() != null

    fun isCurrent(session: Long): Boolean = session == generation.get()

    /**
     * Starts one scene. Returns "busy" when a start is already pending,
     * another lifecycle operation owns the attempt, or this call is reentered
     * from the result callback before it returns. [destroySdk] runs before
     * the new session and again if init throws. A null return means the SDK
     * call returned or init failed terminally.
     *
     * Must run on the main thread. Initialization-failure delivery runs after
     * the lifecycle lock is released and before this call returns. A resolve
     * callback may arrive concurrently on an SDK thread while initialization
     * is still in progress.
     */
    fun launch(
        onResult: (FusionTerminal) -> Unit,
        destroySdk: () -> Unit,
        startSdk: (session: Long) -> Unit,
    ): String? {
        assertMainThread()
        val claim = Any()
        if (!launchOwner.compareAndSet(null, claim)) return "busy"
        var terminal: Delivery? = null
        try {
            lifecycle.lock()
            try {
                if (hasPending()) return "busy"
                destroySdk()
                generation.incrementAndGet()
                val session = generation.incrementAndGet()
                // Never re-arm a gate that an older SDK callback may still reference.
                val gate = firstGate.getAndSet(null) ?: FusionStartGate()
                gate.reset()
                if (!gate.arm()) return "busy"
                attempt.set(Attempt(session, gate, onResult))
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
                won?.send()
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
        terminal?.send()
    }

    /**
     * Delivers on the calling thread, without acquiring the initialization lock.
     * onResult must be thread-safe; FusionAuthPlugin.succeed posts to main.
     */
    fun resolve(session: Long, token: String?, code: String, message: String) {
        // SDK callbacks must not wait for SDK initialization to release its lock:
        // some SDKs join the callback thread during initialization. Instead each
        // generation owns an immutable gate/callback pair, never reset for retry.
        val current = attempt.get() ?: return
        if (current.id != session || !isCurrent(session)) return
        val terminal = current.gate.complete(code, message, token) ?: return
        current.pending.getAndSet(null)?.invoke(terminal)
    }

    /** Caller holds [lifecycle]. Does not invoke the result callback. */
    private fun completeLocked(destroySdk: () -> Unit, code: String, message: String): Delivery? {
        val current = attempt.get()
        val terminal = current?.gate?.complete(code, message, null)
        generation.incrementAndGet()
        val callback = if (terminal != null) current.pending.getAndSet(null) else null
        destroySdk()
        return if (terminal != null && callback != null) Delivery(terminal, callback) else null
    }

    private fun assertMainThread() {
        check(isMainThread()) {
            "FusionSceneController launch and release must run on the main thread"
        }
    }
}
