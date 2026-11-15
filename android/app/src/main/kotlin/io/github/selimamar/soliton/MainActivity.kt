package io.github.selimamar.soliton

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Adds "soliton/save_file": saves a file the app made (a backup, from
 * Settings → Storage) where the person picks, with Android's own "Save to…"
 * screen (Downloads, Drive, an SD card…). The file is copied straight there:
 * unlike the share sheet, no other copy stays in the app's cache.
 */
class MainActivity : FlutterActivity() {
    private var pending: Pair<File, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "save") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val name = call.argument<String>("name")
            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
            val file = path?.let { File(it).canonicalFile }
            when {
                pending != null -> result.error("busy", "Already saving a file", null)
                file == null || name == null || !file.isFile -> result.error("bad_file", "No such file", null)
                // Only files the app itself made, in its own cache folders.
                !isInsideOwnCache(file) -> result.error("bad_file", "Not one of the app's files", null)
                else -> {
                    pending = file to result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(mimeType)
                        .putExtra(Intent.EXTRA_TITLE, name)
                    startActivityForResult(intent, REQUEST)
                }
            }
        }
    }

    @Deprecated("Activity result API of the plain Activity FlutterActivity extends")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val (file, result) = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // Cancelled: nothing saved.
            return
        }
        Thread {
            try {
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: throw IllegalStateException("Can't write there")
                output.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
                val label = displayName(uri) ?: ""
                runOnUiThread { result.success(label) }
            } catch (error: Exception) {
                // Don't leave a partial copy where it was going.
                try {
                    DocumentsContract.deleteDocument(contentResolver, uri)
                } catch (_: Exception) {
                }
                runOnUiThread { result.error("write_failed", error.message, null) }
            }
        }.start()
    }

    private fun isInsideOwnCache(file: File): Boolean =
        listOf(cacheDir, codeCacheDir).any { file.path.startsWith(it.canonicalPath + File.separator) }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    } catch (_: Exception) {
        null
    }

    private companion object {
        const val CHANNEL = "soliton/save_file"
        const val REQUEST = 4207
    }
}
