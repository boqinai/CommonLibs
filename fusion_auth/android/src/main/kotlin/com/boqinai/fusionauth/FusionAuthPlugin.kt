package com.boqinai.fusionauth

import android.app.Activity
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import com.alicom.fusion.auth.AlicomFusionAuthCallBack
import com.alicom.fusion.auth.AlicomFusionBusiness
import com.alicom.fusion.auth.AlicomFusionLog
import com.alicom.fusion.auth.HalfWayVerifyResult
import com.alicom.fusion.auth.error.AlicomFusionEvent
import com.alicom.fusion.auth.token.AlicomFusionAuthToken
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Aliyun 融合认证 to Dart (channel `boqinai/fusion_auth`).
 *
 * start → SDK scene → onVerifySuccess/onHalfWayVerifySuccess resolves the
 * pending `start` with the verify token → Dart verifies it on the host's server
 * → finish(success) continues the scene (closes pages, or lets the SDK fall
 * back). Any other end of the scene resolves `start` without a token.
 */
class FusionAuthPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var business: AlicomFusionBusiness? = null
    private var templateId = ""
    @Volatile private var authToken = ""
    private val pending = AtomicReference<MethodChannel.Result?>(null)
    private val gate = FusionStartGate()
    private var halfWay: HalfWayVerifyResult? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "boqinai/fusion_auth")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        release("cancelled", "")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() {
        activity = null
        release("cancelled", "")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "finish" -> {
                finish(call.argument<Boolean>("success") == true)
                result.success(null)
            }
            "cancel" -> {
                release("cancelled", "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val act = activity ?: return result.error("no_activity", "No foreground activity", null)
        val token = call.argument<String>("token").orEmpty()
        val scheme = call.argument<String>("schemeCode").orEmpty()
        val template = call.argument<String>("templateId").orEmpty()
        if (token.isEmpty() || scheme.isEmpty() || template.isEmpty()) {
            return result.error("bad_args", "token, schemeCode and templateId are required", null)
        }
        if (pending.get() != null) return result.error("busy", "A fusion scene is already running", null)
        destroyBusiness()
        gate.reset()
        if (!gate.arm() || !pending.compareAndSet(null, result)) {
            gate.reset()
            pending.compareAndSet(result, null)
            return result.error("busy", "A fusion scene is already running", null)
        }
        templateId = template
        authToken = token
        try {
            // Umeng is not bundled; the SDK detects that and skips it.
            AlicomFusionBusiness.useSDKSupplyUMSDK(false, "fusion_auth")
            AlicomFusionLog.setLogEnable(false)
            val b = AlicomFusionBusiness()
            business = b
            b.initWithToken(act.applicationContext, scheme, AlicomFusionAuthToken().apply { setAuthToken(token) })
            b.setAlicomFusionAuthCallBack(callback)
            b.startSceneWithTemplateId(act, template)
        } catch (t: Throwable) {
            // One terminal status. release used to complete pending as cancelled
            // after resolve posted start_failed asynchronously.
            release("start_failed", t.message ?: t.javaClass.simpleName)
        }
    }

    private fun finish(success: Boolean) = main.post {
        val b = business ?: return@post
        val hw = halfWay
        halfWay = null
        if (hw != null) hw.verifyResult(success) else b.continueSceneWithTemplateId(templateId, success)
    }

    private fun resolve(token: String?, code: String, message: String) {
        val won = gate.complete(code, message, token) ?: return
        deliver(won)
    }

    private fun release(code: String, message: String) {
        destroyBusiness()
        val won = gate.complete(code, message, null) ?: return
        deliver(won)
    }

    private fun deliver(terminal: FusionTerminal) {
        val result = pending.getAndSet(null) ?: return
        val payload = mapOf(
            "verifyToken" to terminal.verifyToken,
            "code" to terminal.code,
            "message" to terminal.message,
        )
        if (Looper.myLooper() == Looper.getMainLooper()) {
            result.success(payload)
        } else {
            main.post { result.success(payload) }
        }
    }

    private fun destroyBusiness() {
        val b = business
        business = null
        halfWay = null
        if (b != null) {
            try {
                if (templateId.isNotEmpty()) b.stopSceneWithTemplateId(templateId)
                b.destory()
            } catch (_: Throwable) {}
        }
    }

    private fun AlicomFusionEvent?.code() = this?.errorCode.orEmpty()
    private fun AlicomFusionEvent?.msg() = this?.errorMsg.orEmpty()

    private val callback = object : AlicomFusionAuthCallBack {
        // Asks Dart for a refreshed 鉴权Token (method `onTokenUpdate`). If the
        // host does not answer within a few seconds, or we are already on the
        // main thread (cannot block), the token from `start` is reused.
        // Auth tokens typically expire in ~3600s; hosts that keep a scene open
        // that long should supply FusionAuth.onTokenUpdate.
        override fun onSDKTokenUpdate(): AlicomFusionAuthToken {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                return AlicomFusionAuthToken().apply { setAuthToken(authToken) }
            }
            val latch = CountDownLatch(1)
            var refreshed = authToken
            main.post {
                try {
                    channel.invokeMethod("onTokenUpdate", null, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val t = result as? String
                            if (!t.isNullOrBlank()) {
                                authToken = t
                                refreshed = t
                            }
                            latch.countDown()
                        }
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            latch.countDown()
                        }
                        override fun notImplemented() {
                            latch.countDown()
                        }
                    })
                } catch (_: Throwable) {
                    latch.countDown()
                }
            }
            try {
                latch.await(8, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            return AlicomFusionAuthToken().apply { setAuthToken(refreshed) }
        }

        override fun onSDKTokenAuthSuccess() {}

        override fun onSDKTokenAuthFailure(token: AlicomFusionAuthToken?, event: AlicomFusionEvent?) {
            resolve(null, event.code(), event.msg())
            main.post { release("cancelled", "") }
        }

        override fun onVerifySuccess(token: String?, nodeName: String?, event: AlicomFusionEvent?) {
            resolve(token, event.code(), event.msg())
        }

        override fun onHalfWayVerifySuccess(
            nodeName: String?, maskToken: String?, event: AlicomFusionEvent?, result: HalfWayVerifyResult?,
        ) {
            main.post { halfWay = result }
            resolve(maskToken, event.code(), event.msg())
        }

        override fun onVerifyFailed(event: AlicomFusionEvent?, nodeName: String?) {
            // Let the template move to its fallback node (as the demo does).
            main.post { business?.continueSceneWithTemplateId(templateId, false) }
        }

        override fun onTemplateFinish(event: AlicomFusionEvent?) {
            resolve(null, event.code(), event.msg())
            main.post { release("cancelled", "") }
        }

        override fun onAuthEvent(event: AlicomFusionEvent?) {}

        override fun onGetPhoneNumberForVerification(nodeName: String?, event: AlicomFusionEvent?): String = ""

        // Interrupts are progress notices (e.g. 900003/900004 start/end
        // loading) while the template keeps running; the demo only toasts
        // them. The scene still ends through onTemplateFinish.
        override fun onVerifyInterrupt(event: AlicomFusionEvent?) {}
    }
}
