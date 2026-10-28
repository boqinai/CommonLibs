package com.boqinai.fusionauth

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Plugin-level fusion start session. SDK init is [launch]'s [startSdk]
 * callback. A throw completes the pending start once, as `start_failed`.
 * A later cancel cannot replace that terminal status. Callbacks captured
 * with the session id from [launch] are ignored after [release] moves the
 * generation counter.
 */
class FusionSceneController(
    private val gate: FusionStartGate = FusionStartGate(),
) {
    private val generation = AtomicLong()
    private val pending = AtomicReference<((FusionTerminal) -> Unit)?>(null)

    /**
     * Launch ownership, independent of [pending] and [gate]. Only the caller
     * that wins this claim may reset the gate, tear down the SDK, or start
     * the session. A concurrent launch returns "busy" without those calls.
     */
    private val launchOwner = AtomicReference<Any?>(null)

    fun hasPending(): Boolean = pending.get() != null

    fun isCurrent(session: Long): Boolean = session == generation.get()

    /**
     * Starts one scene. Returns "busy" when a start is already pending or
     * another launch owns the attempt. [destroySdk] runs before the new
     * session and again if init throws. A null return means the SDK call
     * returned or init failed terminally.
     */
    fun launch(
        onResult: (FusionTerminal) -> Unit,
        destroySdk: () -> Unit,
        startSdk: (session: Long) -> Unit,
    ): String? {
        val claim = Any()
        if (!launchOwner.compareAndSet(null, claim)) return "busy"
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
            return try {
                startSdk(session)
                null
            } catch (error: Throwable) {
                release(destroySdk, "start_failed", error.message ?: error.javaClass.simpleName)
                null
            }
        } finally {
            launchOwner.compareAndSet(claim, null)
        }
    }

    fun release(destroySdk: () -> Unit, code: String, message: String) {
        val won = gate.complete(code, message, null)
        generation.incrementAndGet()
        destroySdk()
        if (won != null) deliver(won)
    }

    fun resolve(session: Long, token: String?, code: String, message: String) {
        if (!isCurrent(session)) return
        val won = gate.complete(code, message, token) ?: return
        deliver(won)
    }

    private fun deliver(terminal: FusionTerminal) {
        val callback = pending.getAndSet(null) ?: return
        callback(terminal)
    }
}
