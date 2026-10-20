package com.boqinai.app_update

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest

internal object ApkInstallValidator {
    data class Result(
        val valid: Boolean,
        val code: String? = null,
        val message: String? = null,
    )

    fun validate(context: Context, apk: File): Result {
        if (!apk.isFile) {
            return Result(false, "file_not_found", "Downloaded APK does not exist")
        }

        return try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }
            val archive = context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
                ?: return Result(false, "invalid_apk", "Unable to read APK package information")
            if (archive.packageName != context.packageName) {
                return Result(
                    false,
                    "apk_package_mismatch",
                    "APK package ${archive.packageName} does not match ${context.packageName}",
                )
            }

            val installed = context.packageManager.getPackageInfo(context.packageName, flags)
            if (!hasCompatibleSigners(installed, archive)) {
                return Result(
                    false,
                    "apk_signature_mismatch",
                    "APK signing certificate does not match the installed application",
                )
            }
            Result(true)
        } catch (error: Exception) {
            Result(false, "invalid_apk", error.message ?: "Unable to validate APK")
        }
    }

    private fun hasCompatibleSigners(installed: PackageInfo, archive: PackageInfo): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            val installedSigners = installed.signatures?.map(::fingerprint)?.toSet().orEmpty()
            @Suppress("DEPRECATION")
            val archiveSigners = archive.signatures?.map(::fingerprint)?.toSet().orEmpty()
            return installedSigners.isNotEmpty() && installedSigners == archiveSigners
        }

        val installedInfo = installed.signingInfo ?: return false
        val archiveInfo = archive.signingInfo ?: return false
        val installedCurrent = installedInfo.apkContentsSigners.map(::fingerprint).toSet()
        val archiveCurrent = archiveInfo.apkContentsSigners.map(::fingerprint).toSet()
        if (installedCurrent.isEmpty() || archiveCurrent.isEmpty()) return false

        // Android only supports signing-certificate rotation for a single signer. APKs
        // with multiple signers must retain the exact signer set.
        if (installedCurrent.size > 1 || archiveCurrent.size > 1) {
            return installedCurrent == archiveCurrent
        }

        val archiveHistory = archiveInfo.signingCertificateHistory
            ?.map(::fingerprint)
            ?.toSet()
            .orEmpty() + archiveCurrent
        // A valid rotation candidate contains the currently installed signer in
        // its authenticated signing history. Checking this direction prevents an
        // older certificate from being accepted merely because it appears in the
        // installed application's past lineage.
        return installedCurrent.all(archiveHistory::contains)
    }

    private fun fingerprint(signature: android.content.pm.Signature): String =
        MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
