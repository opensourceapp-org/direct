# WebRTC uses JNI callbacks into these classes.
-keep class org.webrtc.** { *; }
# BouncyCastle lightweight API used by the core for Ed25519, X25519, and HKDF.
-keep class org.bouncycastle.crypto.** { *; }
-dontwarn org.bouncycastle.**
# kotlinx.serialization for the encrypted local store.
-keepclassmembers class app.direct.core.store.** { *** Companion; *** serializer(...); }
-keep,includedescriptorclasses class app.direct.core.store.**$$serializer { *; }
-keep class com.google.zxing.** { *; }
-dontwarn com.google.zxing.**
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn coil.**
-dontwarn com.valentinilk.shimmer.**
