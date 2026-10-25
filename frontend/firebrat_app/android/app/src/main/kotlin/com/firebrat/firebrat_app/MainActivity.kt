package com.firebrat.firebrat_app

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    private var integrityChannel: IntegrityChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Play Integrity stub: token minting only, no launch gating.
        integrityChannel = IntegrityChannel(this, flutterEngine.dartExecutor)
    }

    override fun onDestroy() {
        integrityChannel?.detach()
        integrityChannel = null
        super.onDestroy()
    }
}
