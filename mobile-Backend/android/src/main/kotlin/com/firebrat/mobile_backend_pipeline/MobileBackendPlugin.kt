package com.firebrat.mobile_backend_pipeline

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Offline page rendering, registered in both the UI and conversion engines. */
class MobileBackendPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "firebrat/local_pdf")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "renderPage" && call.method != "pageCount") { result.notImplemented(); return }
        val path = call.argument<String>("path")
        val output = call.argument<String>("output")
        val index = call.argument<Int>("page")
        if (path == null || (call.method == "renderPage" && (output == null || index == null))) {
            result.error("arguments", "Missing PDF rendering arguments", null); return
        }
        executor.execute {
            try {
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { renderer ->
                        if (call.method == "pageCount") {
                            val count = renderer.pageCount
                            main.post { result.success(count) }
                            return@execute
                        }
                        renderer.openPage(index!!).use { page ->
                            val scale = minOf(2.0, 1600.0 / maxOf(page.width, page.height))
                            val bitmap = Bitmap.createBitmap((page.width * scale).toInt(), (page.height * scale).toInt(), Bitmap.Config.ARGB_8888)
                            try {
                                bitmap.eraseColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                File(output!!).parentFile?.mkdirs()
                                File(output!!).outputStream().use { stream ->
                                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
                                }
                            } finally { bitmap.recycle() }
                        }
                    }
                }
                main.post { result.success(output) }
            } catch (e: Exception) {
                main.post { result.error("pdf_render", e.message, null) }
            }
        }
    }
}
