package com.boqinai.app_update

import java.io.File

/**
 * Publishes a staged APK onto [destination]. The previous file is renamed to
 * `destination.bak` first. If a timeout wins the [DownloadTaskGate] during the
 * swap, rollback puts that backup back and deletes only the staged `.ready`
 * file, so an installable APK remains.
 */
fun commitReadyApk(
    gate: DownloadTaskGate,
    ready: File,
    destination: File,
    beforeSeal: () -> Unit = {},
): Boolean {
    val backup = File(destination.absolutePath + ".bak")
    var backedUp = false
    val committed = gate.tryCommitSuccess(
        commit = {
            if (backup.exists()) backup.delete()
            if (destination.exists()) {
                if (!destination.renameTo(backup)) {
                    destination.copyTo(backup, overwrite = true)
                    destination.delete()
                }
                backedUp = true
            }
            if (!ready.renameTo(destination)) {
                ready.copyTo(destination, overwrite = true)
                ready.delete()
            }
            beforeSeal()
        },
        rollback = {
            if (backedUp && backup.exists()) {
                if (destination.exists()) destination.delete()
                if (!backup.renameTo(destination)) {
                    backup.copyTo(destination, overwrite = true)
                    backup.delete()
                }
            } else if (!backedUp && destination.exists() && !ready.exists()) {
                destination.delete()
            }
            if (ready.exists()) ready.delete()
        },
    )
    if (committed && backup.exists()) backup.delete()
    return committed
}
