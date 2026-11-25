package io.github.thezenox.thermalab

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var encoder: VideoEncoder? = null
    private var micResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A live camera view: keep the screen on while the app is in front.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "t2s_thermal/video")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            encoder?.finish()
                            encoder = VideoEncoder(
                                call.argument<String>("path")!!,
                                call.argument<Int>("width")!!,
                                call.argument<Int>("height")!!,
                                call.argument<Int>("fps") ?: 15,
                                call.argument<Boolean>("audio") == true && hasMic(),
                            )
                            result.success(encoder!!.hasAudio)
                        }
                        "micPermission" -> {
                            // Asked only when the user switches sound on.
                            if (hasMic()) {
                                result.success(true)
                            } else {
                                micResult?.success(false)
                                micResult = result
                                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
                            }
                        }
                        "frame" -> {
                            encoder?.addFrame(call.arguments as ByteArray)
                            result.success(null)
                        }
                        "stop" -> {
                            val path = encoder?.finish()
                            encoder = null
                            result.success(path)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("video", e.message, null)
                }
            }
    }

    private fun hasMic() =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_REQUEST) {
            micResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            micResult = null
        }
    }

    override fun onDestroy() {
        encoder?.finish()
        encoder = null
        super.onDestroy()
    }

    companion object {
        private const val MIC_REQUEST = 7301
    }
}
