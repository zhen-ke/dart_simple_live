# R8 只处理 Java/Kotlin 侧：Dart 代码是 AOT 编译进 libapp.so 的，不参与混淆。
# 因此这里的规则只影响 Flutter embedding 与插件。
#
# io.flutter.app / plugin / util / view / plugins / embedding 都在 io.flutter 之下，
# 原来那 5 条更窄的 -keep 完全被这一条覆盖，已合并为一条等价规则。
-keep class io.flutter.** { *; }

# 通过 JNI/反射调用，需保留
-keep class de.prosiebensat1digital.** { *; }

# 不再使用 -ignorewarnings：
# 它会连同反射类库的真实缺失告警一起吞掉，导致问题推迟到运行时才暴露。
# 如果 release 构建出现 missing class 告警，请针对具体包补
# -dontwarn <包名>，不要恢复全局静默。
