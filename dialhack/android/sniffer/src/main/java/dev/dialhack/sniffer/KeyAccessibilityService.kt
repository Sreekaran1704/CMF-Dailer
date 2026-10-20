package dev.dialhack.sniffer

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/** Media keys path B: does a key-filtering accessibility service see Bluetooth AVRCP keys? */
class KeyAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        SnifferLog.init(this)
        SnifferLog.write("control", "a11y", "connected")
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (SnifferLog.isMediaOrVolumeKey(event.keyCode)) {
            SnifferLog.key("a11y.onKeyEvent", event)
        }
        return false // observe only
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        SnifferLog.write("control", "a11y", "disconnected")
        super.onDestroy()
    }
}
