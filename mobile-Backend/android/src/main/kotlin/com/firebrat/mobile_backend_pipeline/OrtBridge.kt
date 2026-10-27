package com.firebrat.mobile_backend_pipeline

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtLoggingLevel
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ai.onnxruntime.OnnxJavaType
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Thin ONNX Runtime session bridge (channel `firebrat/ort`) used for speech models.
 * Unlike the generic flutter_onnxruntime plugin it exposes NNAPI flags (fp16 relaxation,
 * CPU disabled), per-session profiling (which provider really ran each node), verbose
 * logging, and moves tensors as typed arrays (no boxed lists), which matters for audio.
 */
class OrtBridge(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "firebrat/ort")
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val sessions = ConcurrentHashMap<String, OrtSession>()
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init { channel.setMethodCallHandler(this) }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    private fun reply(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("ort_bridge", e.message ?: e.toString(), e.stackTraceToString()) }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> reply(result) { create(call) }
            "run" -> reply(result) { run(call) }
            "close" -> reply(result) { close(call.argument<String>("id")!!, call.argument<Boolean>("profile") ?: false) }
            else -> result.notImplemented()
        }
    }

    private fun create(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("path")!!
        val provider = call.argument<String>("provider") ?: "cpu"
        val threads = call.argument<Int>("threads") ?: 2
        val nnapiFlags = call.argument<Int>("nnapiFlags") ?: 0
        val verbose = call.argument<Boolean>("verbose") ?: false
        val profilePrefix = call.argument<String>("profilePrefix")
        val opts = OrtSession.SessionOptions()
        opts.setIntraOpNumThreads(threads)
        opts.setInterOpNumThreads(1)
        if (verbose) {
            opts.setSessionLogLevel(OrtLoggingLevel.ORT_LOGGING_LEVEL_VERBOSE)
            opts.setSessionLogVerbosityLevel(1)
        }
        if (profilePrefix != null) opts.enableProfiling(profilePrefix)
        val info = HashMap<String, Any?>()
        when (provider) {
            "nnapi" -> {
                val flags = EnumSet.noneOf(NNAPIFlags::class.java)
                if (nnapiFlags and 1 != 0) flags.add(NNAPIFlags.USE_FP16)
                if (nnapiFlags and 2 != 0) flags.add(NNAPIFlags.USE_NCHW)
                if (nnapiFlags and 4 != 0) flags.add(NNAPIFlags.CPU_DISABLED)
                if (nnapiFlags and 8 != 0) flags.add(NNAPIFlags.CPU_ONLY)
                opts.addNnapi(flags)
            }
            // No own thread count: XNNPACK then shares ORT's intra-op pool. Passing one made it spawn a
            // second pool (8 threads on 4 cores) and run ~2x slower.
            "xnnpack" -> opts.addXnnpack(emptyMap())
        }
        val session = env.createSession(path, opts)
        val id = UUID.randomUUID().toString()
        sessions[id] = session
        info["id"] = id
        info["inputs"] = session.inputNames.toList()
        info["outputs"] = session.outputNames.toList()
        return info
    }

    @Suppress("UNCHECKED_CAST")
    private fun run(call: MethodCall): Map<String, Any?> {
        val session = sessions[call.argument<String>("id")!!] ?: error("unknown session")
        val inputs = call.argument<List<Map<String, Any?>>>("inputs")!!
        val tensors = ArrayList<OnnxTensor>()
        val feed = HashMap<String, OnnxTensor>()
        try {
            for (input in inputs) {
                val name = input["name"] as String
                val shape = (input["shape"] as List<Number>).map { it.toLong() }.toLongArray()
                val data = input["data"]
                val tensor = when (data) {
                    is LongArray -> OnnxTensor.createTensor(env, LongBuffer.wrap(data), shape)
                    is FloatArray -> OnnxTensor.createTensor(env, FloatBuffer.wrap(data), shape)
                    is ByteArray -> {
                        // raw bytes: used for float16 tensors (native byte order, IEEE half)
                        val bb = ByteBuffer.allocateDirect(data.size).order(ByteOrder.nativeOrder())
                        bb.put(data); bb.rewind()
                        OnnxTensor.createTensor(env, bb, shape, OnnxJavaType.FLOAT16)
                    }
                    else -> error("unsupported tensor data ${data?.javaClass}")
                }
                tensors.add(tensor)
                feed[name] = tensor
            }
            val start = System.nanoTime()
            val out = session.run(feed)
            val ms = (System.nanoTime() - start) / 1_000_000.0
            val outputs = ArrayList<Map<String, Any?>>()
            try {
                for (entry in out) {
                    val t = entry.value as OnnxTensor
                    val shape = t.info.shape.toList()
                    val data: Any = when (t.info.type) {
                        OnnxJavaType.INT64 -> { val b = t.longBuffer; LongArray(b.remaining()).also { b.get(it) } }
                        OnnxJavaType.FLOAT16 -> { val b = t.byteBuffer; ByteArray(b.remaining()).also { b.get(it) } }
                        else -> { val b = t.floatBuffer; FloatArray(b.remaining()).also { b.get(it) } }
                    }
                    outputs.add(mapOf("name" to entry.key, "shape" to shape, "data" to data))
                }
            } finally { out.close() }
            return mapOf("outputs" to outputs, "ms" to ms)
        } finally { tensors.forEach { it.close() } }
    }

    private fun close(id: String, profile: Boolean): String? {
        val s = sessions.remove(id) ?: return null
        val path = if (profile) s.endProfiling() else null
        s.close()
        return path
    }
}
