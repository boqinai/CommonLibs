package com.boqinai.fusionauth

import java.util.concurrent.atomic.AtomicBoolean

/** One deferred scene start per SDK initialization, after authentication succeeds. */
internal class FusionSceneStartGate {
    private val queued = AtomicBoolean(false)

    fun authenticated(isCurrent: () -> Boolean, dispatch: (() -> Unit) -> Unit, start: () -> Unit) {
        if (!isCurrent() || !queued.compareAndSet(false, true)) return
        dispatch {
            // A cancellation or replacement between callback and UI dispatch must not open a page.
            if (isCurrent()) start()
        }
    }
}
