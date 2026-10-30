package com.boqinai.fusionauth

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
    private val scene = FusionSceneController(
        isMainThread = { Looper.myLooper() == Looper.getMainLooper() },
    )
    private var halfWay: HalfWayVerifyResult? = null
    private val authWatchdog = FusionAuthWatchdog()
    private var debugLogging = false
    private fun debugInfo(message: String) { if (debugLogging) Log.i("FusionAuth", message) }
    private fun debugWarn(message: String) { if (debugLogging) Log.w("FusionAuth", message) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        debugLogging = (binding.applicationContext.applicationInfo.flags and
            android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
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
        if (scene.hasPending() || business != null) {
            return result.error("busy", "A fusion scene is already running", null)
        }
        val rejected = scene.launch(
            onResult = { terminal -> succeed(result, terminal) },
            destroySdk = { destroySdk() },
            startSdk = { session ->
                templateId = template
                authToken = token
                // Umeng is not bundled; the SDK detects that and skips it.
                AlicomFusionBusiness.useSDKSupplyUMSDK(false, "fusion_auth")
                AlicomFusionLog.setLogEnable(false)
                val b = AlicomFusionBusiness()
                business = b
                authWatchdog.arm(
                    schedule = { action ->
                        val task = Runnable { action() }
                        main.postDelayed(task, 15_000L)
                        val cancel: () -> Unit = { main.removeCallbacks(task) }
                        cancel
                    },
                    expired = {
                        if (scene.isCurrent(session) && scene.hasPending()) {
                            release("sdk_auth_timeout", "SDK token authentication timed out")
                        }
                    },
                )
                debugInfo("stage=initializing")
                try {
                    b.initWithToken(act.applicationContext, scheme, AlicomFusionAuthToken().apply { setAuthToken(token) })
                } catch (error: Throwable) {
                    debugWarn("stage=init_failed type=${error.javaClass.simpleName}")
                    throw error
                }
                // initWithToken creates the SDK's authProxy. Registering before it
                // dereferences null inside setAlicomFusionAuthCallBack.
                b.setAlicomFusionAuthCallBack(callback(session, b, template))
                debugInfo("stage=waiting_for_token_auth")
                // Start only after token authentication; an early start is ignored by the SDK.
            },
        )
        if (rejected == "busy") {
            result.error("busy", "A fusion scene is already running", null)
        }
    }

    private fun finish(success: Boolean) {
        val sdk = business ?: return
        val template = templateId
        main.post {
            if (business !== sdk) return@post
            val hw = halfWay
            halfWay = null
            if (hw != null) hw.verifyResult(success) else sdk.continueSceneWithTemplateId(template, success)
        }
    }

    private fun resolve(session: Long, token: String?, code: String, message: String) {
        scene.resolve(session, token, code, message)
    }

    private fun release(code: String, message: String) {
        scene.release(::destroySdk, code, message)
    }

    private fun succeed(result: MethodChannel.Result, terminal: FusionTerminal) {
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

    private fun destroySdk() {
        authWatchdog.cancel()
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

    private fun callback(session: Long, sdk: AlicomFusionBusiness, template: String) = object : AlicomFusionAuthCallBack {
        private fun active(): Boolean = scene.isCurrent(session)

        // Asks Dart for a refreshed 鉴权Token (method `onTokenUpdate`). If the
        // host does not answer within a few seconds, or we are already on the
        // main thread (cannot block), the token from `start` is reused.
        // Auth tokens typically expire in ~3600s; hosts that keep a scene open
        // that long should supply FusionAuth.onTokenUpdate.
        override fun onSDKTokenUpdate(): AlicomFusionAuthToken {
            if (!active()) return AlicomFusionAuthToken().apply { setAuthToken("") }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                return AlicomFusionAuthToken().apply { setAuthToken(authToken) }
            }
            val latch = CountDownLatch(1)
            var refreshed = authToken
            main.post {
                if (!active()) {
                    latch.countDown()
                    return@post
                }
                try {
                    channel.invokeMethod("onTokenUpdate", null, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val t = result as? String
                            if (active() && !t.isNullOrBlank()) {
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
            return AlicomFusionAuthToken().apply { setAuthToken(if (active()) refreshed else "") }
        }

        private val sceneStart = FusionSceneStartGate()

        override fun onSDKTokenAuthSuccess() {
            main.post { if (active()) authWatchdog.cancel() }
            debugInfo("stage=token_authenticated")
            // Token refresh may report success again. Start the scene once per generation,
            // on the main thread and after the SDK callback returns (per Aliyun's contract).
            sceneStart.authenticated(
                isCurrent = ::active,
                dispatch = { action -> main.post { action() } },
                start = {
                    val act = activity
                    if (act == null) {
                        release("start_failed", "No foreground activity for the fusion scene")
                    } else {
                        try {
                            debugInfo("stage=starting_scene")
                            sdk.startSceneWithTemplateId(act, template)
                        } catch (error: Throwable) {
                            debugWarn("stage=scene_start_failed type=${error.javaClass.simpleName}")
                            release("start_failed", "Unable to start the fusion scene")
                        }
                    }
                },
            )
        }

        override fun onSDKTokenAuthFailure(token: AlicomFusionAuthToken?, event: AlicomFusionEvent?) {
            if (!active()) return
            debugWarn("stage=token_auth_failed code=${event.code()}")
            main.post { if (active()) authWatchdog.cancel() }
            // Preserve the SDK code/message contract exposed by earlier versions.
            resolve(session, null, event.code(), event.msg())
            main.post { if (active()) release("cancelled", "") }
        }

        override fun onVerifySuccess(token: String?, nodeName: String?, event: AlicomFusionEvent?) {
            if (!active()) return
            resolve(session, token, event.code(), event.msg())
        }

        override fun onHalfWayVerifySuccess(
            nodeName: String?, maskToken: String?, event: AlicomFusionEvent?, result: HalfWayVerifyResult?,
        ) {
            if (!active()) return
            main.post { if (active()) halfWay = result }
            resolve(session, maskToken, event.code(), event.msg())
        }

        override fun onVerifyFailed(event: AlicomFusionEvent?, nodeName: String?) {
            if (!active()) return
            debugWarn("stage=verification_failed code=${event.code()}")
            // Let the template move to its fallback node (as the demo does).
            main.post { if (active()) sdk.continueSceneWithTemplateId(template, false) }
        }

        override fun onTemplateFinish(event: AlicomFusionEvent?) {
            if (!active()) return
            debugInfo("stage=scene_finished code=${event.code()}")
            resolve(session, null, event.code(), event.msg())
            main.post { if (active()) release("cancelled", "") }
        }

        override fun onAuthEvent(event: AlicomFusionEvent?) {
            if (active()) debugInfo("stage=auth_event code=${event.code()}")
        }

        override fun onGetPhoneNumberForVerification(nodeName: String?, event: AlicomFusionEvent?): String = ""

        // Interrupts are progress notices (e.g. 900003/900004 start/end
        // loading) while the template keeps running; the demo only toasts
        // them. The scene still ends through onTemplateFinish.
        override fun onVerifyInterrupt(event: AlicomFusionEvent?) {
            if (active()) debugInfo("stage=verify_interrupt code=${event.code()}")
        }
    }
}
