package com.boqinai.carrierauth

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import androidx.core.content.ContextCompat
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.mobile.auth.gatewayauth.AuthUIConfig
import com.mobile.auth.gatewayauth.PhoneNumberAuthHelper
import com.mobile.auth.gatewayauth.TokenResultListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Direct carrier SDK entry point. Never starts the fusion scene engine. */
class CarrierAuthPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var activity: Activity? = null
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "boqinai/carrier_auth")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        finish("cancelled")
        activity = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { finish("cancelled"); activity = null }
    override fun onDetachedFromActivity() { finish("cancelled"); activity = null }

    private val main = Handler(Looper.getMainLooper())
    private var helper: PhoneNumberAuthHelper? = null
    private var pending: MethodChannel.Result? = null
    private var generation = 0L
    private var timeout: Runnable? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "cancel" -> { finish("cancelled"); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val host = activity ?: run { result.success(mapOf("code" to "unavailable")); return }
        val key = call.argument<String>("sdkKey").orEmpty()
        val appearance = call.argument<Map<String, Number>>("appearance").orEmpty()
        val agreements = call.argument<List<Map<String, String>>>("agreements").orEmpty()
        if (agreements.isEmpty() || agreements.size > 3 || agreements.any {
            it["title"].isNullOrBlank() || android.net.Uri.parse(it["url"].orEmpty()).let { uri -> uri.scheme != "https" || uri.host.isNullOrBlank() }
        }) { result.success(mapOf("code" to "bad_args")); return }
        val sdkTimeout = call.argument<Number>("sdkTimeoutMs")?.toInt() ?: 10_000
        val authorizationTimeout = call.argument<Number>("authorizationTimeoutMs")?.toLong() ?: 180_000L
        if (sdkTimeout !in 1..60_000 || authorizationTimeout !in 1L..1_800_000L) {
            result.success(mapOf("code" to "bad_args")); return
        }

        if (pending != null) { result.error("busy", "Authorization is active", null); return }
        if (key.isBlank() || host.isFinishing) { result.success(mapOf("code" to "unavailable")); return }
        pending = result
        val request = ++generation
        try {
            val listener = object : TokenResultListener {
                override fun onTokenSuccess(raw: String) = handle(request, raw)
                override fun onTokenFailed(raw: String) = handle(request, raw)
            }
            val sdk = PhoneNumberAuthHelper.getInstance(host.applicationContext, listener)
            helper = sdk
            sdk.setAuthListener(listener)
            sdk.setAuthSDKInfo(key)
            fun color(role: String, fallback: Int) = appearance[role]?.toInt() ?: fallback
            val surface = color("surfaceColor", Color.WHITE)
            val text = color("textColor", Color.rgb(32,32,32))
            val secondary = color("secondaryTextColor", Color.rgb(102,102,102))
            val primary = color("primaryColor", Color.rgb(37,99,235))
            val onPrimary = color("onPrimaryColor", Color.WHITE)
            val link = color("linkColor", Color.rgb(29,78,216))
            fun button(fill: Int) = GradientDrawable().apply { setColor(fill); cornerRadius = (appearance["cornerRadius"]?.toFloat() ?: 12f) * host.resources.displayMetrics.density }
            val background = StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_pressed), button(color("pressedColor", primary)))
                addState(intArrayOf(), button(primary))
            }
            val builder = AuthUIConfig.Builder()
                .setNavText(call.argument<String>("title") ?: "本机号码登录")
                .setNavColor(surface)
                .setStatusBarColor(surface)
                .setPageBackgroundDrawable(ColorDrawable(surface))
                .setNavTextColor(text)
                .setLogoImgDrawable(ContextCompat.getDrawable(host, host.applicationInfo.icon))
                .setLogoWidth(64).setLogoHeight(64).setLogoOffsetY(48)
                .setNumberColor(text).setNumberSize(appearance["numberTextSize"]?.toInt() ?: 28)
                .setNumFieldOffsetY(144)
                .setSloganTextColor(secondary).setSloganOffsetY(196)
                .setLogBtnText(call.argument<String>("loginButtonText") ?: "本机号码一键登录")
                .setLogBtnTextColor(onPrimary).setLogBtnTextSize(appearance["buttonTextSize"]?.toInt() ?: 16)
                .setLogBtnHeight(48).setLogBtnMarginLeftAndRight(24)
                .setLogBtnOffsetY(244).setLogBtnBackgroundDrawable(background)
                .setSwitchAccHidden(false).setSwitchAccText(call.argument<String>("smsButtonText") ?: "使用短信验证码登录")
                .setSwitchAccTextColor(link).setSwitchOffsetY(312)
                .setPrivacyState(false)
                .setAppPrivacyColor(secondary, link)

            agreements.forEachIndexed { index, agreement ->
                when (index) {
                    0 -> builder.setAppPrivacyOne(agreement["title"], agreement["url"])
                    1 -> builder.setAppPrivacyTwo(agreement["title"], agreement["url"])
                    2 -> builder.setAppPrivacyThree(agreement["title"], agreement["url"])
                }
            }
            sdk.setAuthUIConfig(builder.create())
            sdk.setUIClickListener { code, _, _ ->
                if (code == "700001") main.post { if (request == generation) finish("switch_sms") }
            }
            timeout = Runnable { if (request == generation) finish("600015") }.also {
                main.postDelayed(it, authorizationTimeout)
            }
            Log.i("CarrierAuth", "stage=opening_authorization")
            sdk.getLoginToken(host, sdkTimeout)
        } catch (_: Exception) {
            finish("start_failed")
        }
    }

    private fun handle(request: Long, raw: String) {
        main.post {
            if (request != generation || pending == null) return@post
            val json = try { JSONObject(raw) } catch (_: Exception) { finish("invalid_result"); return@post }
            val code = json.optString("code")
            // Only stable status codes are logged. Provider payloads contain credentials.
            if (code.matches(Regex("[0-9]{1,12}"))) Log.i("CarrierAuth", "code=$code")
            if (code == "600012" || code == "600011") logFailure(json)
            when (code) {
                "600001" -> Unit // Real masked number is now visible; await consent.
                "600000" -> {
                    val token = json.optString("token")
                    if (token.isEmpty()) finish("invalid_result") else finish(code, token)
                }
                "700000" -> finish("cancelled")
                "700001" -> finish("switch_sms")
                "700002", "700003", "700004" -> Unit // UI events are not failures.
                else -> finish(code)
            }
        }
    }

    /** Whitelist diagnostic codes/messages; never log the SDK payload or tokens. */
    private fun logFailure(value: JSONObject, depth: Int = 0) {
        if (((activity?.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0 || depth > 4) return
        for (key in value.keys()) {
            val item = value.opt(key)
            if (item is JSONObject) { logFailure(item, depth + 1); continue }
            if (item !is String) continue
            val nested = try { JSONObject(item) } catch (_: Exception) { null }
            if (nested != null) { logFailure(nested, depth + 1); continue }
            if (key.lowercase() !in setOf("code", "msg", "message", "resultcode", "resultmsg", "returncode", "errorcode", "errormsg", "innercode", "innerdesc")) continue
            val safe = item.replace(Regex("https?://[^\\s\"']+"), "<url>")
                .replace(Regex("[A-Za-z0-9+/=_-]{24,}"), "<redacted>")
                .replace(Regex("[0-9]{7,}"), "<number>")
                .replace(Regex("[\\r\\n]"), " ").take(160)
            Log.i("CarrierAuth", "failure.$key=$safe")
        }
    }

    private fun finish(code: String, token: String? = null) {
        val reply = pending
        pending = null
        generation++
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        try { helper?.hideLoginLoading(); helper?.quitLoginPage(); helper?.setAuthListener(null) } catch (_: Exception) { }
        helper = null
        reply?.success(if (token == null) mapOf("code" to code) else mapOf("code" to code, "token" to token))
    }

}
