# Huawei HMS SDK & IAP Proguard Rules
-ignorewarnings
-keepattributes *Annotation*
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes Signature
-keepattributes SourceFile,LineNumberTable

-keep class com.huawei.hianalytics.** {*;}
-keep class com.huawei.updatesdk.** {*;}
-keep class com.huawei.hms.** {*;}
-keep interface com.huawei.hms.** {*;}
-keep class com.huawei.agconnect.** {*;}

-dontwarn com.huawei.**
-dontwarn org.bouncycastle.**
