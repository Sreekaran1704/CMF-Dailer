package dev.dialhack.sniffer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.media.VolumeProviderCompat
import androidx.media.session.MediaButtonReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * Phase 0 Android sniffer. Runs all capture candidates at once:
 *  - volume path A: Settings.System ContentObserver + VOLUME_CHANGED_ACTION receiver (STREAM_MUSIC)
 *  - volume path B: MediaSessionCompat with a relative VolumeProviderCompat (toggle in UI)
 *  - media keys path A: MediaSessionCompat.Callback.onMediaButtonEvent (+ the derived callbacks)
 * Path B for media keys lives in KeyAccessibilityService.
 */
class SnifferService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var audio: AudioManager
    private lateinit var session: MediaSessionCompat
    private var observer: ContentObserver? = null
    private var silent: AudioTrack? = null
    private var focus: AudioFocusRequest? = null

    private val lastByMethod = mutableMapOf<String, Int>()
    private var baseline = 0
    private var selfUntil = 0L
    private val selfWindowMs = 400L

    private val volumeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val stream = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
            val value = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_VALUE", -1)
            val prev = intent.getIntExtra("android.media.EXTRA_PREV_VOLUME_STREAM_VALUE", -1)
            onVolume("broadcast.volume_changed", stream, value, prev)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        /** Scrappy Phase 0 handle so guided mode can reset the volume. */
        @Volatile var instance: SnifferService? = null
    }

    /** Sets STREAM_MUSIC to the baseline as a tagged self-change (logged as kind "self"). */
    fun resetToBaseline() {
        Handler(Looper.getMainLooper()).post {
            selfUntil = SystemClock.uptimeMillis() + selfWindowMs
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, baseline, 0)
            SnifferLog.write("control", "restore.set", "STREAM_MUSIC", mapOf("baseline" to baseline, "reason" to "guided_reset"))
        }
    }

    fun musicVolume(): Int = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
    fun musicMax(): Int = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    fun bluetoothOutputs(): List<String> = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        .filter { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
        .map { it.productName.toString() }

    override fun onCreate() {
        super.onCreate()
        SnifferLog.init(this)
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)

        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        baseline = max / 2
        val outputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
            .map { "${it.productName} (type ${it.type})" }
        SnifferLog.write(
            "control", "service", "start",
            mapOf(
                "music_volume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                "music_max" to max,
                "baseline" to baseline,
                "bt_outputs" to outputs,
                "sdk" to android.os.Build.VERSION.SDK_INT,
                "device_model" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
            ),
        )

        setupSession()
        registerVolumeWatchers()

        scope.launch { SnifferConfig.silentAudio.collect { setSilent(it) } }
        scope.launch { SnifferConfig.remoteVolume.collect { setVolumeMode(it) } }
        scope.launch {
            SnifferConfig.restore.collect { SnifferLog.write("control", "restore", if (it) "on" else "off") }
        }
        SnifferConfig.serviceRunning.value = true
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == Intent.ACTION_MEDIA_BUTTON) {
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)?.let {
                SnifferLog.key("media_button_receiver.intent", it)
            }
            MediaButtonReceiver.handleIntent(session, intent)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        scope.cancel()
        setSilent(false)
        observer?.let { contentResolver.unregisterContentObserver(it) }
        unregisterReceiver(volumeReceiver)
        session.isActive = false
        session.release()
        SnifferConfig.serviceRunning.value = false
        SnifferLog.write("control", "service", "stop")
        super.onDestroy()
    }

    // region media session

    private fun setupSession() {
        val mbrIntent = Intent(Intent.ACTION_MEDIA_BUTTON).setComponent(ComponentName(this, MediaButtonReceiver::class.java))
        session = MediaSessionCompat(this, "DialSniffer").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onMediaButtonEvent(mediaButtonEvent: Intent): Boolean {
                    IntentCompat.getParcelableExtra(mediaButtonEvent, Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)?.let {
                        SnifferLog.key("session.onMediaButtonEvent", it)
                    }
                    // Let the compat layer derive onPlay/onSkipToNext/etc. so we can log those too.
                    return super.onMediaButtonEvent(mediaButtonEvent)
                }

                override fun onPlay() = cb("onPlay")
                override fun onPause() = cb("onPause")
                override fun onStop() = cb("onStop")
                override fun onSkipToNext() = cb("onSkipToNext")
                override fun onSkipToPrevious() = cb("onSkipToPrevious")
                override fun onFastForward() = cb("onFastForward")
                override fun onRewind() = cb("onRewind")
                override fun onSeekTo(pos: Long) = cb("onSeekTo", mapOf("pos" to pos))
            })
            setPlaybackState(
                PlaybackStateCompat.Builder()
                    .setActions(
                        PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                            PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_STOP or
                            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackStateCompat.ACTION_FAST_FORWARD or PlaybackStateCompat.ACTION_REWIND,
                    )
                    .setState(PlaybackStateCompat.STATE_PLAYING, 0, 1f)
                    .build(),
            )
            setMetadata(
                MediaMetadataCompat.Builder()
                    .putString(MediaMetadataCompat.METADATA_KEY_TITLE, "DialSniffer")
                    .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "DialHack")
                    .build(),
            )
            setMediaButtonReceiver(PendingIntent.getBroadcast(this@SnifferService, 0, mbrIntent, PendingIntent.FLAG_IMMUTABLE))
            isActive = true
        }
        SnifferLog.write("control", "session", "active")
    }

    private fun cb(name: String, extra: Map<String, Any?> = emptyMap()) {
        SnifferLog.write("capture", "session.callback", name, extra)
    }

    private fun setVolumeMode(remote: Boolean) {
        if (remote) {
            session.setPlaybackToRemote(object : VolumeProviderCompat(VOLUME_CONTROL_RELATIVE, 100, 50) {
                override fun onAdjustVolume(direction: Int) {
                    val raw = when {
                        direction > 0 -> "VOLUME_UP"
                        direction < 0 -> "VOLUME_DOWN"
                        else -> "ADJUST_SAME"
                    }
                    SnifferLog.write("capture", "session.volumeProvider.onAdjustVolume", raw, mapOf("direction" to direction))
                }

                override fun onSetVolumeTo(volume: Int) {
                    SnifferLog.write("capture", "session.volumeProvider.onSetVolumeTo", "SET", mapOf("value" to volume))
                }
            })
        } else {
            session.setPlaybackToLocal(AudioManager.STREAM_MUSIC)
        }
        SnifferLog.write("control", "volume_mode", if (remote) "remote_provider" else "local")
    }

    // endregion

    // region volume path A

    private fun registerVolumeWatchers() {
        val music = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        lastByMethod["settings_observer"] = music
        observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                val path = uri?.lastPathSegment ?: ""
                if (!path.contains("volume")) return
                onVolume("settings_observer", AudioManager.STREAM_MUSIC, audio.getStreamVolume(AudioManager.STREAM_MUSIC), null, path)
            }
        }
        contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, observer!!)
        ContextCompat.registerReceiver(
            this, volumeReceiver, IntentFilter("android.media.VOLUME_CHANGED_ACTION"), ContextCompat.RECEIVER_EXPORTED,
        )
    }

    private fun onVolume(method: String, stream: Int, value: Int, reportedPrev: Int?, uri: String? = null) {
        val now = SystemClock.uptimeMillis()
        val prev = reportedPrev?.takeIf { it >= 0 } ?: lastByMethod[method]
        lastByMethod[method] = value
        val delta = if (prev != null) value - prev else 0
        val raw = when {
            delta > 0 -> "VOLUME_UP"
            delta < 0 -> "VOLUME_DOWN"
            else -> "VOLUME_SAME"
        }
        val isMusic = stream == AudioManager.STREAM_MUSIC
        val inWindow = now < selfUntil
        val atBaseline = value == baseline
        val isSelf = isMusic && inWindow && atBaseline
        // Raw before/after rescaled to AVRCP absolute-volume units (0..127), matching the mac log.
        val max = if (stream >= 0) audio.getStreamMaxVolume(stream) else 0
        val scale = if (max > 0) 127.0 / max else 0.0
        fun to127(x: Int?) = x?.let { Math.round(it * scale * 100) / 100.0 }
        SnifferLog.write(
            if (isSelf) "self" else if (isMusic) "capture" else "control", method, raw,
            mapOf(
                "stream" to stream, "value" to value, "prev" to prev, "delta" to delta, "max" to max,
                "before_127" to to127(prev), "after_127" to to127(value), "step_127" to to127(delta),
                "at_limit" to (value <= 0 || value >= max),
                "self_window" to inWindow, "at_baseline" to atBaseline, "uri" to uri,
            ),
        )
        if (isMusic && !isSelf && SnifferConfig.restore.value) maybeRestore()
    }

    /** Idempotent: several watchers may fire for the same change; only restore if still off-baseline. */
    private fun maybeRestore() {
        val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        if (current == baseline) return
        selfUntil = SystemClock.uptimeMillis() + selfWindowMs
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, baseline, 0)
        SnifferLog.write("control", "restore.set", "STREAM_MUSIC", mapOf("from" to current, "baseline" to baseline, "diff" to abs(current - baseline)))
    }

    // endregion

    // region silent audio

    private fun setSilent(on: Boolean) {
        if (on == (silent != null)) return
        if (on) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener { SnifferLog.write("control", "audio_focus", it.toString()) }
                .build()
            val focusResult = audio.requestAudioFocus(req)
            focus = req

            val rate = 44100
            val frames = rate // one second of silence, looped
            val track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(frames * 4)
                .build()
            track.write(ShortArray(frames * 2), 0, frames * 2)
            track.setLoopPoints(0, frames, -1)
            track.play()
            silent = track
            SnifferLog.write("control", "silent_audio", "on", mapOf("focus_result" to focusResult))
        } else {
            silent?.run { stop(); release() }
            silent = null
            focus?.let { audio.abandonAudioFocusRequest(it) }
            focus = null
            SnifferLog.write("control", "silent_audio", "off")
        }
    }

    // endregion

    private fun notification(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel("sniffer", "DialSniffer", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, "sniffer")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("DialSniffer running")
            .setContentText("Logging dial events")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}
