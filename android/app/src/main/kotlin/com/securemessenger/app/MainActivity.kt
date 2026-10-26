package com.securemessenger.app

import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "secure_messenger/screen_privacy")
            .setMethodCallHandler { call, result ->
                if (call.method == "setProtected") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        // Point 6: real "save to device" support. Writing into the app's
        // private directory (what path_provider gives us on Android) is
        // invisible to Gallery/Files, which is why saves appeared to do
        // nothing. MediaStore publishes into the shared collections and needs
        // no runtime permission on Android 10+.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "secure_messenger/media_store")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveFile") {
                    try {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType")
                        val kind = call.argument<String>("kind") ?: "file"
                        if (sourcePath == null || fileName == null) {
                            result.error("bad_args", "sourcePath and fileName are required", null)
                        } else {
                            result.success(saveToMediaStore(sourcePath, fileName, mimeType, kind))
                        }
                    } catch (error: Exception) {
                        result.error("save_failed", error.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "secure_messenger/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAutoStartSettings" -> result.success(openAutoStartSettings())
                    "openAppInfo" -> result.success(openAppInfo())
                    "isHibernationExempt" -> result.success(isHibernationExempt())
                    "setHibernationExempt" -> result.success(setHibernationExempt())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Publishes a file into the correct shared MediaStore collection so it
     * shows up in Gallery / Music / Downloads like any other saved file.
     *
     * Returns the public content:// URI as a string.
     *
     * On API 29+ this needs no permission at all. On API 28 and below we fall
     * back to the legacy public directory, which is covered by the
     * WRITE_EXTERNAL_STORAGE permission the Dart side requests first.
     */
    private fun saveToMediaStore(
        sourcePath: String,
        fileName: String,
        mimeType: String?,
        kind: String
    ): String {
        val source = File(sourcePath)
        if (!source.exists()) throw IllegalArgumentException("source file missing")
        val resolvedMime = mimeType ?: when (kind) {
            "image" -> "image/jpeg"
            "video" -> "video/mp4"
            "audio" -> "audio/mpeg"
            else -> "application/octet-stream"
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val legacyDir = when (kind) {
                "image" -> Environment.DIRECTORY_PICTURES
                "video" -> Environment.DIRECTORY_MOVIES
                "audio" -> Environment.DIRECTORY_MUSIC
                else -> Environment.DIRECTORY_DOWNLOADS
            }
            val target = File(
                Environment.getExternalStoragePublicDirectory(legacyDir),
                "Reyno"
            )
            if (!target.exists()) target.mkdirs()
            val outFile = uniqueFile(target, fileName)
            source.copyTo(outFile, overwrite = false)
            // Make it visible to the gallery scanner right away.
            sendBroadcast(
                Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(outFile))
            )
            return Uri.fromFile(outFile).toString()
        }

        val collection = when (kind) {
            "image" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "audio" -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relative = when (kind) {
            "image" -> "${Environment.DIRECTORY_PICTURES}/Reyno"
            "video" -> "${Environment.DIRECTORY_MOVIES}/Reyno"
            "audio" -> "${Environment.DIRECTORY_MUSIC}/Reyno"
            else -> "${Environment.DIRECTORY_DOWNLOADS}/Reyno"
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, resolvedMime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            // IS_PENDING hides a half-written file from other apps.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore rejected the insert")
        try {
            resolver.openOutputStream(uri).use { output ->
                if (output == null) throw IllegalStateException("no output stream")
                source.inputStream().use { input -> input.copyTo(output) }
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    /** photo.jpg -> photo (1).jpg when the name is taken (legacy path only). */
    private fun uniqueFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var index = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($index)$ext")
            index++
        }
        return candidate
    }

    /**
     * Opens the vendor autostart manager so background work (keep-alive
     * service, WorkManager) survives after the app is swiped away. Falls
     * back to the app-details settings page.
     */
    private fun openAutoStartSettings(): Boolean {
        val candidates = listOf(
            // Xiaomi (MIUI / HyperOS)
            Intent("miui.intent.action.OP_AUTO_START"),
            Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            ),
            // Huawei (EMUI / HarmonyOS)
            Intent().setComponent(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                )
            ),
            Intent().setComponent(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity"
                )
            ),
            // Oppo / Realme (ColorOS)
            Intent().setComponent(
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                )
            ),
            Intent().setComponent(
                ComponentName(
                    "com.oppo.safe",
                    "com.oppo.safe.permission.startup.StartupAppListActivity"
                )
            ),
            // Vivo (Funtouch / OriginOS)
            Intent().setComponent(
                ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                )
            ),
            Intent().setComponent(
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"
                )
            ),
            // OnePlus (OxygenOS)
            Intent().setComponent(
                ComponentName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                )
            ),
            // Samsung
            Intent().setComponent(
                ComponentName(
                    "com.samsung.android.sm_cn",
                    "com.samsung.android.sm.ui.ram.AutoRunActivity"
                )
            ),
            // Asus
            Intent().setComponent(
                ComponentName(
                    "com.asus.mobilemanager",
                    "com.asus.mobilemanager.powersaver.PowerSaverSettings"
                )
            ),
            // Nokia (evenwell)
            Intent().setComponent(
                ComponentName(
                    "com.evenwell.powersaving.g3",
                    "com.evenwell.powersaving.g3.exception.PowerSaverExceptionActivity"
                )
            )
        )
        for (intent in candidates) {
            try {
                intent.addCategory(Intent.CATEGORY_DEFAULT)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) {
            }
        }
        // Fall back to the app-details page (hosts the autostart-adjacent toggles
        // on ROMs without a dedicated manager).
        return openAppInfo()
    }

    private fun openAppInfo(): Boolean {
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * True when Android's "Pause app activity if unused" is OFF for us, i.e.
     * the system may not hibernate the app (which would freeze the keep-alive
     * service and cancel background work). Below Android 11 the feature does
     * not exist, so there is nothing to exempt.
     */
    private fun isHibernationExempt(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return try {
            packageManager.isAutoRevokeWhitelisted(packageName)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Best-effort self-exemption from app hibernation. Returns the resulting
     * state: some ROMs refuse programmatic changes (SecurityException) and
     * the user must flip the toggle in App Info manually.
     */
    private fun setHibernationExempt(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        try {
            packageManager.setAutoRevokeWhitelisted(packageName, true)
        } catch (_: Exception) {
            // Refused: the UI falls back to guiding the user to App Info.
        }
        return isHibernationExempt()
    }
}
