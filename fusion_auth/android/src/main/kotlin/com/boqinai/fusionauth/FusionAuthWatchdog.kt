package com.boqinai.fusionauth

/** Initial SDK token-auth deadline, with injected scheduling for deterministic JVM tests. */
internal class FusionAuthWatchdog {
    private val lock = Any()
    private var owner: Any? = null
    private var cancelTask: (() -> Unit)? = null

    fun arm(schedule: (() -> Unit) -> (() -> Unit), expired: () -> Unit) {
        cancel()
        val marker = Any()
        synchronized(lock) { owner = marker }
        val cancellation = schedule {
            val fire = synchronized(lock) {
                if (owner !== marker) false else {
                    owner = null
                    cancelTask = null
                    true
                }
            }
            if (fire) expired()
        }
        val obsolete = synchronized(lock) {
            if (owner === marker) { cancelTask = cancellation; false } else true
        }
        if (obsolete) cancellation()
    }

    fun cancel() {
        val cancellation = synchronized(lock) {
            owner = null
            val task = cancelTask
            cancelTask = null
            task
        }
        cancellation?.invoke()
    }
}
