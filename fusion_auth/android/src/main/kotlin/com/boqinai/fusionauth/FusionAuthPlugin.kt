package com.boqinai.fusionauth

import android.app.Activity
import android.os.Handler
import android.os.Looper
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
    private var pending: MethodChannel.Result? = null
    private var halfWay: HalfWayVerifyResult? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "boqinai/fusion_auth")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        release()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() {
        activity = null
        release()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "finish" -> {
                finish(call.argument<Boolean>("success") == true)
                result.success(null)
            }
            "cancel" -> {
                release()
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
        if (pending != null) return result.error("busy", "A fusion scene is already running", null)
        release()
        pending = result
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
            resolve(null, "start_failed", t.message ?: t.javaClass.simpleName)
            release()
        }
    }

    private fun finish(success: Boolean) = main.post {
        val b = business ?: return@post
        val hw = halfWay
        halfWay = null
        if (hw != null) hw.verifyResult(success) else b.continueSceneWithTemplateId(templateId, success)
    }

    private fun resolve(token: String?, code: String, message: String) = main.post {
        val r = pending ?: return@post
        pending = null
        r.success(mapOf("verifyToken" to token, "code" to code, "message" to message))
    }

    private fun release() {
        val b = business
        business = null
        halfWay = null
        if (b != null) {
            try {
                if (templateId.isNotEmpty()) b.stopSceneWithTemplateId(templateId)
                b.destory()
            } catch (_: Throwable) {}
        }
        pending?.let {
            pending = null
            it.success(mapOf("verifyToken" to null, "code" to "cancelled", "message" to ""))
        }
    }

    private fun AlicomFusionEvent?.code() = this?.errorCode.orEmpty()
    private fun AlicomFusionEvent?.msg() = this?.errorMsg.orEmpty()

    private val callback = object : AlicomFusionAuthCallBack {
        // Called when the SDK wants a fresh 鉴权Token; the host issues a new one
        // per login attempt, so the current one is still the best we have.
        override fun onSDKTokenUpdate(): AlicomFusionAuthToken =
            AlicomFusionAuthToken().apply { setAuthToken(authToken) }

        override fun onSDKTokenAuthSuccess() {}

        override fun onSDKTokenAuthFailure(token: AlicomFusionAuthToken?, event: AlicomFusionEvent?) {
            resolve(null, event.code(), event.msg())
            main.post { release() }
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
            main.post { release() }
        }

        override fun onAuthEvent(event: AlicomFusionEvent?) {}

        override fun onGetPhoneNumberForVerification(nodeName: String?, event: AlicomFusionEvent?): String = ""

        // Interrupts are progress notices (e.g. 900003/900004 start/end
        // loading) while the template keeps running; the demo only toasts
        // them. The scene still ends through onTemplateFinish.
        override fun onVerifyInterrupt(event: AlicomFusionEvent?) {}
    }
}
