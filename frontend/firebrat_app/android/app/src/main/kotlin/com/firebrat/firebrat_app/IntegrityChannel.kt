package com.firebrat.firebrat_app

import android.app.Activity
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Play Integrity token path (production-ready minting, lib-1).
 *
 * Exposes token minting over `firebrat/integrity` only. No enforcement,
 * no gating, no server verification — callers decide policy in Dart
 * ([IntegrityService]) and the playback path never calls this.
 *
 * Methods:
 * - `prepareStandard` {cloudProjectNumber: long} — warms the standard
 *   provider. Must precede `requestStandard`. Re-preparing with the same
 *   project number reuses the cached provider.
 * - `requestStandard` {requestHash: String} — returns {token: String}.
 * - `requestClassic` {nonce: String} — legacy single-shot token,
 *   returns {token: String}. Prefer standard on new code.
 *
 * Errors surface as MethodChannel errors with stable codes mapped from
 * Play exceptions (see [errorCodeOf]); Dart maps them to retryable
 * (offline/transient → queue) vs non-retryable (fail-closed remote,
 * fail-open local) policy itself. All replies are posted on the UI thread.
 */
class IntegrityChannel(private val activity: Activity, dartExecutor: DartExecutor) {
    private val channel = MethodChannel(dartExecutor.binaryMessenger, CHANNEL)
    private val integrityManager = IntegrityManagerFactory.create(activity.applicationContext)
    private val standardManager: StandardIntegrityManager =
        IntegrityManagerFactory.createStandard(activity.applicationContext)
    private var standardProvider: StandardIntegrityTokenProvider? = null
    private var preparedProjectNumber: Long? = null

    init {
        channel.setMethodCallHandler(::handle)
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareStandard" -> prepareStandard(call, result)
            "requestStandard" -> requestStandard(call, result)
            "requestClassic" -> requestClassic(call, result)
            else -> result.notImplemented()
        }
    }

    private fun successOnUi(result: MethodChannel.Result, value: Any?) {
        activity.runOnUiThread { result.success(value) }
    }

    private fun errorOnUi(result: MethodChannel.Result, code: String, message: String?) {
        activity.runOnUiThread { result.error(code, message, null) }
    }

    private fun prepareStandard(call: MethodCall, result: MethodChannel.Result) {
        val projectNumber = (call.argument<Number>("cloudProjectNumber"))?.toLong()
            ?: return errorOnUi(result, INVALID_ARGS, "cloudProjectNumber (long) is required")
        if (projectNumber <= 0) {
            return errorOnUi(result, INVALID_ARGS, "cloudProjectNumber must be positive")
        }
        if (preparedProjectNumber == projectNumber && standardProvider != null) {
            return successOnUi(result, null)
        }
        try {
            standardManager.prepareIntegrityToken(
                PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(projectNumber).build(),
            ).addOnSuccessListener { provider ->
                standardProvider = provider
                preparedProjectNumber = projectNumber
                successOnUi(result, null)
            }.addOnFailureListener { e ->
                errorOnUi(result, errorCodeOf(e), e.message)
            }
        } catch (e: Exception) {
            errorOnUi(result, errorCodeOf(e), e.message)
        }
    }

    private fun requestStandard(call: MethodCall, result: MethodChannel.Result) {
        val provider = standardProvider
            ?: return errorOnUi(
                result,
                NOT_PREPARED,
                "Call prepareStandard first — no StandardIntegrityTokenProvider cached.",
            )
        val requestHash = call.argument<String>("requestHash")
            ?: return errorOnUi(result, INVALID_ARGS, "requestHash (String) is required")
        if (requestHash.isBlank()) {
            return errorOnUi(result, INVALID_ARGS, "requestHash must not be blank")
        }
        if (requestHash.length > 500) {
            return errorOnUi(result, INVALID_ARGS, "requestHash exceeds 500 chars")
        }
        try {
            provider.request(
                StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build(),
            ).addOnSuccessListener { response ->
                successOnUi(result, mapOf("token" to response.token()))
            }.addOnFailureListener { e ->
                // A dead provider (e.g. -113) is useless for later calls —
                // drop it so the next mint re-prepares instead of reusing it.
                if (errorCodeOf(e) == "INTEGRITY_TOKEN_PROVIDER_INVALID") {
                    standardProvider = null
                    preparedProjectNumber = null
                }
                errorOnUi(result, errorCodeOf(e), e.message)
            }
        } catch (e: Exception) {
            errorOnUi(result, errorCodeOf(e), e.message)
        }
    }

    private fun requestClassic(call: MethodCall, result: MethodChannel.Result) {
        val nonce = call.argument<String>("nonce")
            ?: return errorOnUi(result, INVALID_ARGS, "nonce (String) is required")
        if (nonce.isBlank()) {
            return errorOnUi(result, INVALID_ARGS, "nonce must not be blank")
        }
        try {
            integrityManager.requestIntegrityToken(
                IntegrityTokenRequest.builder().setNonce(nonce).build(),
            ).addOnSuccessListener { response ->
                successOnUi(result, mapOf("token" to response.token()))
            }.addOnFailureListener { e ->
                errorOnUi(result, errorCodeOf(e), e.message)
            }
        } catch (e: Exception) {
            errorOnUi(result, errorCodeOf(e), e.message)
        }
    }

    companion object {
        const val CHANNEL = "firebrat/integrity"
        const val NOT_PREPARED = "NOT_PREPARED"
        const val INVALID_ARGS = "INVALID_ARGS"

        /**
         * Maps Play Integrity throwables to stable channel error codes.
         * IntegrityServiceException/StandardIntegrityException both expose
         * getErrorCode(); anything else is INTERNAL. Codes follow
         * IntegrityResponseCode / StandardIntegrityResponseCode values.
         *
         * Dart treats NETWORK_ERROR, GOOGLE_SERVER_UNAVAILABLE,
         * CLIENT_TRANSIENT_ERROR, TOO_MANY_REQUESTS, CANNOT_BIND_TO_SERVICE
         * and API_NOT_AVAILABLE as retryable (queue offline); the rest are
         * fail-closed for remote calls and fail-open for local use.
         */
        fun errorCodeOf(e: Throwable): String {
            val code = runCatching {
                val m = e.javaClass.getMethod("getErrorCode")
                (m.invoke(e) as? Int) ?: return@runCatching null
            }.getOrNull() ?: return "INTERNAL"
            return when (code) {
                -100 -> "API_NOT_AVAILABLE"
                -101 -> "PLAY_STORE_NOT_FOUND"
                -102 -> "NETWORK_ERROR"
                -103 -> "PLAY_STORE_VERSION_OUTDATED"
                -104 -> "PLAY_SERVICES_NOT_FOUND"
                -105 -> "PLAY_SERVICES_VERSION_OUTDATED"
                -106 -> "CANNOT_BIND_TO_SERVICE"
                -107 -> "NONCE_TOO_SHORT"
                -108 -> "NONCE_TOO_LONG"
                -109 -> "NONCE_IS_NOT_BASE64"
                -110 -> "GOOGLE_SERVER_UNAVAILABLE"
                -111 -> "PLAY_STORE_ACCOUNT_NOT_FOUND"
                -112 -> "APP_NOT_INSTALLED"
                -113 -> "INTEGRITY_TOKEN_PROVIDER_INVALID"
                -114 -> "CLOUD_PROJECT_NUMBER_IS_INVALID"
                -115 -> "REQUEST_HASH_TOO_LONG"
                -116 -> "CLIENT_TRANSIENT_ERROR"
                -117 -> "TOO_MANY_REQUESTS"
                else -> "INTEGRITY_$code"
            }
        }
    }
}
