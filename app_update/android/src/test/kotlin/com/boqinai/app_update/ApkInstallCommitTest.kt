package com.boqinai.app_update

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

fun main() {
    successReplacesAndDropsBackup()
    timeoutBeforeCommitDeletesOnlyReady()
    timeoutDuringCommitRestoresPreviousApk()
    timeoutDuringCommitWithNoPreviousDeletesNewFile()
    serviceUsesCommitReadyApk()
    println("apk install commit ok")
}

private fun successReplacesAndDropsBackup() {
    val (destination, ready) = apkPair("old-apk", "new-apk")
    val gate = DownloadTaskGate()
    check(commitReadyApk(gate, ready, destination))
    check(destination.readText() == "new-apk")
    check(!ready.exists())
    check(!File(destination.absolutePath + ".bak").exists())
    check(gate.get() == TaskState.SUCCESS)
}

private fun timeoutBeforeCommitDeletesOnlyReady() {
    val (destination, ready) = apkPair("old-apk", "new-apk")
    val gate = DownloadTaskGate()
    check(gate.tryComplete(TaskState.TIMED_OUT))
    check(!commitReadyApk(gate, ready, destination))
    check(destination.readText() == "old-apk")
    check(!ready.exists())
    check(!File(destination.absolutePath + ".bak").exists())
}

private fun timeoutDuringCommitRestoresPreviousApk() {
    val (destination, ready) = apkPair("old-apk", "new-apk")
    val gate = DownloadTaskGate()
    val entered = CountDownLatch(1)
    val resume = CountDownLatch(1)
    val worker = Thread {
        val committed = commitReadyApk(gate, ready, destination) {
            entered.countDown()
            check(resume.await(5, TimeUnit.SECONDS))
        }
        check(!committed)
    }
    worker.start()
    check(entered.await(5, TimeUnit.SECONDS))
    check(gate.tryComplete(TaskState.TIMED_OUT))
    resume.countDown()
    worker.join(5_000)
    check(!worker.isAlive)
    check(destination.readText() == "old-apk") { destination.readText() }
    check(!ready.exists())
    check(!File(destination.absolutePath + ".bak").exists())
    check(gate.get() == TaskState.TIMED_OUT)
}

private fun timeoutDuringCommitWithNoPreviousDeletesNewFile() {
    val dir = Files.createTempDirectory("apk-commit-empty").toFile()
    val destination = File(dir, "app.apk")
    val ready = File(dir, "app.apk.ready")
    ready.writeText("new-apk")
    val gate = DownloadTaskGate()
    check(!commitReadyApk(gate, ready, destination) {
        check(gate.tryComplete(TaskState.TIMED_OUT))
    })
    check(!destination.exists())
    check(!ready.exists())
}

private fun serviceUsesCommitReadyApk() {
    val src = File("app_update/android/src/main/kotlin/com/boqinai/app_update/UpdateDownloadService.kt").readText()
    check(src.contains("commitReadyApk(gate, ready, destination)"))
    check(!src.contains("if (destination.exists()) destination.delete()"))
}

private fun apkPair(oldBytes: String, newBytes: String): Pair<File, File> {
    val dir = Files.createTempDirectory("apk-commit").toFile()
    val destination = File(dir, "app.apk")
    val ready = File(dir, "app.apk.ready")
    destination.writeText(oldBytes)
    ready.writeText(newBytes)
    return destination to ready
}
