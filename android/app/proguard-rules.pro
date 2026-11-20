# R8 规则：压缩 + 混淆业务代码。
# 库的 keep 大多靠各自 AAR 里自带的 consumer-proguard；这里只补 R8 看不穿的反射盲区。

# ---- 高德 地图 / 定位 ----
# 高德大量走 JNI 与内部反射，官方明确要求整体 keep，否则地图黑屏 / 定位回调不触发。
-keep class com.amap.api.** { *; }
-keep class com.amap.** { *; }
-keep class com.autonavi.** { *; }
-keep class com.loc.** { *; }
# 放宽到整个 com.amap.**：定位融合模块会引用可选组件（如 com.amap.ams.gnss.
# GnssSoftLocator、com.amap.location.**），窄到 com.amap.api.** 会漏、R8 报缺类失败。
-dontwarn com.amap.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**

# ---- BouncyCastle（国密 SM2/SM4 握手）----
# 用的是轻量 crypto API（直接 new，不走 JCA provider），但 asn1 命名曲线表等内部有
# 反射注册。整体 keep + dontwarn 最稳——BC 是库，混淆它没意义。
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# ---- OkHttp / Okio（一般自带 consumer 规则，这里补 dontwarn 兜可选依赖）----
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# ---- WorkManager + Room（经 Glance 小组件间接引入 work-runtime → room-runtime 2.2.5）----
# Room 2.2.5（2020）自带的 consumer 规则太老，R8 全模式会改名它靠反射按 "_Impl" 后缀
# 加载的数据库实现类，导致 androidx.startup 初始化 WorkDatabase 时启动即崩。
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep @androidx.room.Database class * { *; }
-dontwarn androidx.work.**
-dontwarn androidx.room.**

# ---- Glance 小组件动作 ----
# actionRunCallback 把回调类名写进 PendingIntent，点击时再用反射调用无参构造。
# R8 看不到这条创建路径，会把构造器裁掉；正式包随后会在每次点击时报
# NoSuchMethodException。保留所有 ActionCallback 实现，也覆盖以后新增的卡片动作。
-keep class * implements androidx.glance.appwidget.action.ActionCallback { *; }

# GlanceAppWidget.updateAll() 按实现类查找对应的 provider。R8 横向合并不同尺寸的卡片类后，
# 小卡和大卡会拥有同一个运行时 class，刷新任意一张都可能把另一张重画成错误版式。
# 这些类必须各自保留；receiver 的类名虽然由 Manifest 自动保留，但只保 receiver 不够。
-keep class org.yipao.app.widget.** extends androidx.glance.appwidget.GlanceAppWidget { *; }

# ---- 保留注解 / 泛型签名 / 内部类关系：别影响 BC 泛型与任何注解读取 ----
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,Exceptions

# 我方说明：
# - 数据模型手写 JsonValue 解析、不靠反射，无需 keep，可放心混淆。
# - WebView 渲染器无 @JavascriptInterface（走 onJsPrompt），Three.js 包在 assets/、
#   不受 shrinkResources 影响（资源压缩只动 res/）。
