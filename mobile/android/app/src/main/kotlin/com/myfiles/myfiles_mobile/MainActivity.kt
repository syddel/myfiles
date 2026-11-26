package com.myfiles.myfiles_mobile

import android.content.Context
import android.net.wifi.WifiManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity shares the Flutter engine with the background audio
// service, so audio keeps playing (and the app reconnects to it) after the
// screen is closed.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Held while audio plays (see lib/audio/service_backend.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "myfiles/wifi_lock").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    AudioWifiLock.hold(applicationContext, true)
                    result.success(null)
                }
                "release" -> {
                    AudioWifiLock.hold(applicationContext, false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

// Keeps Wi-Fi at full power while streaming audio with the screen off, so the
// connection to the server doesn't stall (the same lock ExoPlayer takes in its
// "network" wake mode). Kept outside the activity: audio can play on after the
// activity is gone.
object AudioWifiLock {
    private var lock: WifiManager.WifiLock? = null

    @Suppress("DEPRECATION")
    @Synchronized
    fun hold(context: Context, held: Boolean) {
        if (lock == null) {
            val wifi = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "myfiles:audio").apply {
                setReferenceCounted(false)
            }
        }
        val current = lock ?: return
        if (held && !current.isHeld) current.acquire()
        if (!held && current.isHeld) current.release()
    }
}
