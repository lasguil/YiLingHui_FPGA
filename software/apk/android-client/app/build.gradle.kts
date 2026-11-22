plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
 namespace = "com.efinity.ti60"
 compileSdk = 35
 defaultConfig { applicationId = "com.efinity.ti60"; minSdk = 29; targetSdk = 35; versionCode = 51; versionName = "1.6.16" }
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
 kotlinOptions { jvmTarget = "17" }
 testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
 testImplementation("junit:junit:4.13.2")
 testImplementation("org.json:json:20250107")
}
dependencyLocking { lockAllConfigurations() }
