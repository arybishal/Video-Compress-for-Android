package com.pvideocompress.pure_compress

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {

    private var pendingPick: MethodChannel.Result? = null
    private var pendingNotificationPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "purecompress/native"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "pickVideo" -> startPick(result)
                    "exportToMovies" -> {
                        val src = call.argument<String>("srcPath")!!
                        val name = call.argument<String>("displayName")!!
                        val dir = call.argument<String>("dirName") ?: "PureCompress"
                        val mime = call.argument<String>("mimeType") ?: "video/mp4"
                        exportToMovies(File(src), name, dir, mime) { uri ->
                            if (uri != null) result.success(uri)
                            else result.error("export_failed", "Could not write to MediaStore", null)
                        }
                    }
                    "openWith" -> {
                        val path = call.argument<String>("path")!!
                        val mime = call.argument<String>("mimeType") ?: "video/mp4"
                        openWith(File(path), mime)
                        result.success(null)
                    }
                    "freeBytes" -> {
                        val stat = StatFs(applicationInfo.dataDir)
                        result.success(stat.availableBytes)
                    }
                    "checkNotificationPermission" -> {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                            val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                                this,
                                android.Manifest.permission.POST_NOTIFICATIONS
                            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                            result.success(if (granted) "granted" else "denied")
                        } else {
                            val enabled = androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()
                            result.success(if (enabled) "granted" else "denied")
                        }
                    }
                    "requestNotificationPermission" -> {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                            pendingNotificationPermission = result
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                RC_NOTIF_PERMISSION
                            )
                        } else {
                            val enabled = androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()
                            result.success(if (enabled) "granted" else "denied")
                        }
                    }
                    "openAppSettings" -> {
                        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", packageName, null)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native_error", e.message, null)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_NOTIF_PERMISSION) {
            val pending = pendingNotificationPermission ?: return
            pendingNotificationPermission = null
            val granted = grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            pending.success(if (granted) "granted" else "denied")
        }
    }

    // ------------------------------------------------------------ picking --

    private fun startPick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        pendingPick = result
        // SAF video picker: ACTION_GET_CONTENT("video/*"). The picked content
        // is copied into the app cache so FFmpeg gets a plain file path; the
        // original document is never touched.
        startActivityForResult(
            Intent(Intent.ACTION_GET_CONTENT).apply { type = "video/*" },
            RC_PICK
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == RC_PICK) handlePickedUri(if (resultCode == RESULT_OK) data?.data else null)
    }

    private fun handlePickedUri(uri: Uri?) {
        val pending = pendingPick ?: return
        pendingPick = null
        if (uri == null) {
            pending.success(null)
            return
        }
        Thread {
            val dir = File(cacheDir, "purecompress_pick")
            dir.mkdirs()
            val name = queryDisplayName(uri) ?: "video"
            val ext = name.substringAfterLast('.', "").lowercase()
            val out = File(dir, "${UUID.randomUUID()}${if (ext.isEmpty()) "" else ".$ext"}")
            var copySuccess = false
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(out).use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("Cannot open picked document")
                if (out.length() == 0L) {
                    throw IllegalStateException("Picked video file is empty")
                }
                copySuccess = true
                val map = hashMapOf<String, Any>(
                    "path" to out.absolutePath,
                    "name" to name,
                    "size" to out.length()
                )
                runOnUiThread { pending.success(map) }
            } catch (e: Exception) {
                if (!copySuccess && out.exists()) {
                    out.delete()
                }
                runOnUiThread { pending.error("pick_failed", e.message, null) }
            }
        }.start()
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        return uri.lastPathSegment
    }

    // ------------------------------------------------------------ export ---

    /// Copies a finished video into Movies/<dir> through MediaStore (IS_PENDING
    /// flow). Works on API 29+ without any storage permission.
    private fun exportToMovies(
        src: File,
        displayName: String,
        dirName: String,
        mime: String,
        callback: (String?) -> Unit
    ) {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, mime)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/$dirName")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }
        val collection = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val uri = resolver.insert(collection, values) ?: return callback(null)
        try {
            resolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { input -> input.copyTo(out) }
            } ?: return callback(null)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Video.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            callback(uri.toString())
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            callback(null)
        }
    }

    // -------------------------------------------------------------- play ---

    /// ACTION_VIEW through the FileProvider so any installed player can open
    /// an app-private output file.
    private fun openWith(file: File, mime: String) {
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Open with"))
    }

    companion object {
        private const val RC_PICK = 0x9C
        private const val RC_NOTIF_PERMISSION = 0x9D
    }
}
