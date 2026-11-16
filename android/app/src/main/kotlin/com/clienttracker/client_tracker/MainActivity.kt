package com.clienttracker.client_tracker

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

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

    /** Photos are copied on this thread, never the main one, so a large or
     *  slow share can't freeze the app. One at a time, in order. */
    private val io = Executors.newSingleThreadExecutor()

    /** Shares still being copied, and an "initialShare" call waiting on them. */
    private var copying = 0
    private var waiting: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "client_tracker/share",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // The share the app was opened with, once (after it has
                    // been copied, if that's still going on).
                    "initialShare" ->
                        if (copying > 0) {
                            waiting?.success(null)
                            waiting = result
                        } else {
                            result.success(pending)
                            pending = null
                        }
                    else -> result.notImplemented()
                }
            }
        }
        readShare(intent, initial = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readShare(intent, initial = false)
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    /** Hands a read share to the app (on the main thread). */
    private fun deliver(share: Map<String, Any?>?, initial: Boolean) {
        val ch = channel
        val w = waiting
        when {
            w != null && copying == 0 -> {
                waiting = null
                w.success(share ?: pending)
                pending = null
            }
            share == null -> {}
            initial || ch == null -> pending = share
            else -> ch.invokeMethod("share", share)
        }
    }

    private fun readShare(intent: Intent?, initial: Boolean) {
        if (intent == null) return
        val type = intent.type ?: return
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND ->
                if (type.startsWith("image/")) {
                    listOfNotNull(streamOf(intent))
                } else if (type.startsWith("text/")) {
                    intent.action = null
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                        ?.takeIf { it.isNotBlank() }
                        ?.take(MAX_TEXT)
                    deliver(
                        text?.let { mapOf("photos" to emptyList<String>(), "text" to it) },
                        initial,
                    )
                    return
                } else {
                    return
                }
            Intent.ACTION_SEND_MULTIPLE ->
                if (type.startsWith("image/")) streamsOf(intent) else return
            else -> return
        }
        // Handled: don't hand the same share over again (e.g. on rotate).
        intent.action = null
        if (uris.isEmpty()) return
        copying++
        io.execute {
            val share = photos(uris.take(MAX_PHOTOS))
            runOnUiThread {
                copying--
                deliver(share, initial)
            }
        }
    }

    private fun photos(uris: List<Uri>): Map<String, Any?>? {
        var total = 0L
        val paths = mutableListOf<String>()
        for (uri in uris) {
            val left = MAX_TOTAL_BYTES - total
            if (left <= 0) break
            val file = copyToCache(uri, minOf(MAX_PHOTO_BYTES, left)) ?: continue
            total += file.length()
            paths.add(file.absolutePath)
        }
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

    /** Copies a shared photo into the cache, at most [limit] bytes. Nothing
     *  is left behind if the copy fails, comes out empty or is too big. */
    private fun copyToCache(uri: Uri, limit: Long): File? {
        var file: File? = null
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val ext = when (contentResolver.getType(uri)) {
                "image/png" -> "png"
                "image/webp" -> "webp"
                "image/heic" -> "heic"
                else -> "jpg"
            }
            val out = File(dir, "shared_${System.nanoTime()}.$ext")
            file = out
            var copied = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        copied += n
                        if (copied > limit) throw IOException("Shared photo too large")
                        output.write(buf, 0, n)
                    }
                }
            }
            if (copied > 0) {
                out
            } else {
                out.delete()
                null
            }
        } catch (e: Exception) {
            file?.delete()
            null
        }
    }

    private companion object {
        /** At most this many photos from one share. */
        const val MAX_PHOTOS = 20

        /** A payment screenshot is well under this; bigger files are skipped. */
        const val MAX_PHOTO_BYTES = 15L * 1024 * 1024

        /** All photos of one share together. */
        const val MAX_TOTAL_BYTES = 60L * 1024 * 1024

        /** Shared text (an M-Pesa SMS is a few hundred characters). */
        const val MAX_TEXT = 20_000
    }
}
