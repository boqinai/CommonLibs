package com.boqinai.fusionauth

import java.util.concurrent.atomic.AtomicReference

data class FusionTerminal(
    val code: String,
    val message: String,
    val verifyToken: String?,
)

/**
 * One in-flight fusion start. The first [complete] wins. A later release,
 * including cancelled after an SDK init failure, does not replace it.
 */
class FusionStartGate {
    private enum class Phase { EMPTY, ARMED, DONE }

    private val phase = AtomicReference(Phase.EMPTY)
    private val terminal = AtomicReference<FusionTerminal?>(null)

    fun reset() {
        terminal.set(null)
        phase.set(Phase.EMPTY)
    }

    fun arm(): Boolean = phase.compareAndSet(Phase.EMPTY, Phase.ARMED)

    /** Returns the terminal status when this call wins, otherwise null. */
    fun complete(code: String, message: String, verifyToken: String?): FusionTerminal? {
        if (!phase.compareAndSet(Phase.ARMED, Phase.DONE)) return null
        val won = FusionTerminal(code, message, verifyToken)
        terminal.set(won)
        return won
    }

    fun current(): FusionTerminal? = terminal.get()
}
