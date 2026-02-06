import java.util.Properties
import java.io.FileInputStream
import java.text.SimpleDateFormat // <--- ESTO FALTABA
import java.util.Date             // <--- ESTO FALTABA

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.navcontrol_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.navcontrol_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // --- BLOQUE DE RENOMBRADO AUTOMÁTICO (CORREGIDO) ---
    applicationVariants.all {
        val variant = this
        variant.outputs.all {
            val output = this as? com.android.build.gradle.internal.api.BaseVariantOutputImpl
            if (output != null && variant.buildType.name == "release") {
                // Ahora usamos SimpleDateFormat y Date directamente porque los importamos arriba
                val date = SimpleDateFormat("yyyyMMdd_HHmm").format(Date())
                val newName = "NavControl_v${variant.versionName}_${date}.apk"
                output.outputFileName = newName
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}