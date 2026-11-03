package com.clienttracker.client_tracker

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Share → Client Tracker: payment photos (one or many) or message text
 * (an M-Pesa SMS) arrive here and are handed to the app over the
 * "client_tracker/share" channel. Photos are copied into the app's cache
 * (the share only lends access to them); the app deletes the copies once
 * they've been read.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** A share that arrived before the app was ready to take it. */
    private var pending: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "client_tracker/share",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // The share the app was opened with, once.
                    "initialShare" -> {
                        result.success(pending)
                        pending = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        pending = readShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val share = readShare(intent) ?: return
        val ch = channel
        if (ch == null) {
            pending = share
        } else {
            ch.invokeMethod("share", share)
        }
    }

    private fun readShare(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val type = intent.type ?: return null
        return when (intent.action) {
            Intent.ACTION_SEND ->
                if (type.startsWith("image/")) {
                    photos(listOfNotNull(streamOf(intent)))
                } else if (type.startsWith("text/")) {
                    intent.getStringExtra(Intent.EXTRA_TEXT)
                        ?.takeIf { it.isNotBlank() }
                        ?.let { mapOf("photos" to emptyList<String>(), "text" to it) }
                } else {
                    null
                }
            Intent.ACTION_SEND_MULTIPLE ->
                if (type.startsWith("image/")) photos(streamsOf(intent)) else null
            else -> null
        }?.also {
            // Handled: don't hand the same share over again (e.g. on rotate).
            intent.action = null
        }
    }

    private fun photos(uris: List<Uri>): Map<String, Any?>? {
        val paths = uris.mapNotNull { copyToCache(it) }
        return if (paths.isEmpty()) null else mapOf("photos" to paths, "text" to null)
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri> =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        } ?: emptyList()

    private fun copyToCache(uri: Uri): String? = try {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val ext = when (contentResolver.getType(uri)) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/heic" -> "heic"
            else -> "jpg"
        }
        val file = File(dir, "shared_${System.nanoTime()}.$ext")
        contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { input.copyTo(it) }
        }
        if (file.length() > 0) file.absolutePath else null
    } catch (e: Exception) {
        null
    }
}
