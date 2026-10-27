# 阿里云融合认证 (from the official demo's proguard-rules.pro)
-keep class com.alicom.fusion.auth.** { *; }
-keep class com.mobile.auth.gatewayauth.** { *; }
-keep class com.alicom.tools.** { *; }
-keep class com.nirvana.tools.** { *; }
-keep class com.cmic.sso.sdk.** { *; }
-keep class androidx.core.content.ContextCompat { *; }
-keep class androidx.appcompat.app.AppCompatActivity { *; }
-keep public class * extends android.widget.ImageView { *; }
-keep class androidx.activity.OnBackPressedDispatcher { *; }
-keep class androidx.activity.OnBackPressedCallback { *; }
-keep class androidx.lifecycle.LifecycleOwner { *; }
-dontwarn com.alicom.**
-dontwarn com.mobile.auth.**
-dontwarn com.nirvana.tools.**
-dontwarn com.cmic.sso.sdk.**

# 友盟 is not bundled: the SDK probes it via Class.forName (UmUtils.isUmAvable)
# and skips all Umeng calls when absent; its guarded references need this.
-dontwarn com.umeng.**

-keepclassmembers class * {
   public <init>(org.json.JSONObject);
}
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
