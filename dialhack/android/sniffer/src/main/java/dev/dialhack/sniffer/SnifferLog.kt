package dev.dialhack.sniffer

import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Append-only JSONL logger shared by the service, the accessibility service and the UI.
 * `kind` is one of: capture, self, marker, control (same vocabulary as the macOS sniffer).
 * `mono_ms` is SystemClock.uptimeMillis(), the same clock as KeyEvent.eventTime.
 */
object SnifferLog {
    data class Entry(val mono: Long, val kind: String, val method: String, val raw: String, val detail: String)
    data class Capture(val mono: Long, val method: String, val raw: String, val fields: Map<String, Any?>) {
        val isRelease get() = fields["action"] == "up"
        val step127 get() = (fields["step_127"] as? Number)?.toDouble()
    }

    /** Recent capture events, for guided mode's gesture detection. */
    private val captures = ArrayDeque<Capture>()

    fun capturesSince(t: Long): List<Capture> = synchronized(captures) { captures.filter { it.mono >= t } }

    fun lastCaptureMono(): Long? = synchronized(captures) { captures.lastOrNull()?.mono }

    private const val TAG = "DialSniffer"
    val sessionId: String = UUID.randomUUID().toString()

    private val _recent = MutableStateFlow<List<Entry>>(emptyList())
    val recent: StateFlow<List<Entry>> = _recent

    private val _label = MutableStateFlow("unlabeled")
    val label: StateFlow<String> = _label

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var file: File? = null

    fun init(ctx: Context) {
        if (file == null) {
            file = File(ctx.applicationContext.getExternalFilesDir(null), "sniffer.jsonl")
        }
    }

    fun file(): File? = file

    fun setLabel(newLabel: String) {
        _label.value = newLabel
        write("control", "label", newLabel)
    }

    fun write(kind: String, method: String, raw: String, fields: Map<String, Any?> = emptyMap()) {
        val mono = SystemClock.uptimeMillis()
        val obj = JSONObject().apply {
            put("ts", Instant.now().toString())
            put("platform", "android")
            put("kind", kind)
            put("method", method)
            put("raw", raw)
            put("label", _label.value)
            put("session_id", sessionId)
            put("mono_ms", mono)
            fields.forEach { (k, v) ->
                put(k, when (v) {
                    null -> JSONObject.NULL
                    is Collection<*> -> JSONArray(v)
                    else -> v
                })
            }
        }
        val line = obj.toString()
        Log.d(TAG, line)
        io.execute { file?.appendText(line + "\n") }
        if (kind == "capture") synchronized(captures) {
            captures.addLast(Capture(mono, method, raw, fields))
            while (captures.size > 2000) captures.removeFirst()
        }
        val detail = fields.entries.joinToString(" ") { "${it.key}=${it.value}" }
        _recent.update { (listOf(Entry(mono, kind, method, raw, detail)) + it).take(100) }
    }

    fun key(method: String, ke: KeyEvent, extra: Map<String, Any?> = emptyMap()) {
        val action = when (ke.action) {
            KeyEvent.ACTION_DOWN -> "down"
            KeyEvent.ACTION_UP -> "up"
            else -> ke.action.toString()
        }
        write(
            "capture", method, KeyEvent.keyCodeToString(ke.keyCode).removePrefix("KEYCODE_"),
            mapOf(
                "key_code" to ke.keyCode,
                "action" to action,
                "repeat" to ke.repeatCount,
                "event_time" to ke.eventTime,
                "down_time" to ke.downTime,
                "latency_ms" to SystemClock.uptimeMillis() - ke.eventTime,
                "scan_code" to ke.scanCode,
                "source" to ke.source,
                "device_id" to ke.deviceId,
                "device" to ke.device?.name,
                "flags" to ke.flags,
            ) + extra,
        )
    }

    private val mediaKeys = setOf(
        KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE,
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
        KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_MEDIA_STOP,
        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, KeyEvent.KEYCODE_MEDIA_REWIND,
        KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD, KeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD,
        KeyEvent.KEYCODE_MEDIA_STEP_FORWARD, KeyEvent.KEYCODE_MEDIA_STEP_BACKWARD,
        KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MUTE, KeyEvent.KEYCODE_VOICE_ASSIST,
    )

    /** Only media/volume keys are ever logged, never typing. */
    fun isMediaOrVolumeKey(keyCode: Int) = keyCode in mediaKeys
}

object SnifferConfig {
    val serviceRunning = MutableStateFlow(false)
    val silentAudio = MutableStateFlow(true)
    val remoteVolume = MutableStateFlow(false)
    val restore = MutableStateFlow(false)
}
