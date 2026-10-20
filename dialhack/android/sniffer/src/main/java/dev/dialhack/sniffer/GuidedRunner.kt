package dev.dialhack.sniffer

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.VibratorManager
import android.provider.Settings
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/**
 * Guided Phase 0 test on Android, mirroring the macOS `DialSniffer --guided` protocol: priority-ordered
 * sections, auto-detected gestures, labels and sniffer settings switched automatically.
 * When it finishes it logs `guided complete`; Claude watches logcat for that and pulls the log.
 */
class GuidedRunner(private val ctx: Context) {
    enum class State { INFO, WAITING, GOT, MISS, DONE }

    data class Ui(
        val active: Boolean = false,
        val section: String = "",
        val prompt: String = "",
        val detail: String = "",
        val state: State = State.INFO,
        val progress: Float = 0f,
        val buttons: List<String> = emptyList(),
        val skippable: Boolean = false,
        val notes: List<String> = emptyList(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui

    private val choices = Channel<String>(Channel.CONFLATED)
    @Volatile private var skip = false
    @Volatile var aborted = false

    private var sectionIndex = 0
    private var sectionTitle = ""
    private var stepSize127: Double? = null
    private val completed = mutableListOf<String>()
    private val flags = mutableListOf<String>()

    fun press(button: String) {
        if (button == "__skip") skip = true else choices.trySend(button)
    }

    private val sections = listOf(
        "Idle drift check", "Single press", "Rotation, one click at a time", "Double press", "Triple press",
        "Long press", "Fast spins", "Remote volume provider", "Volume restore test", "Silent audio off",
        "Competing media app",
    )

    private suspend fun runSection(i: Int) {
        when (i) {
            0 -> idleDrift()
            1 -> presses("press_single", "Press the dial ONCE now", 5, 3, blocker = true)
            2 -> rotations()
            3 -> presses("press_double", "DOUBLE-press the dial now", 5, 2)
            4 -> presses("press_triple", "TRIPLE-press the dial now", 5, 2)
            5 -> presses("press_long", "Press and HOLD the dial for 2 seconds, then let go", 3, 2, timeoutMs = 14_000)
            6 -> fastSpins()
            7 -> remoteProvider()
            8 -> restoreTest()
            9 -> silentOff()
            10 -> competingApp()
        }
    }

    // region UI helpers

    private fun show(prompt: String, detail: String = "", state: State = State.INFO) {
        _ui.update {
            it.copy(active = true, section = sectionTitle, prompt = prompt, detail = detail, state = state,
                progress = sectionIndex.toFloat() / sections.size)
        }
    }

    private fun note(line: String) = _ui.update { it.copy(notes = (it.notes + line).takeLast(4)) }

    private suspend fun choose(prompt: String, detail: String, options: List<String>, timeoutMs: Long?, fallback: String): String {
        while (choices.tryReceive().isSuccess) { /* drain */ }
        _ui.update { it.copy(active = true, section = sectionTitle, prompt = prompt, detail = detail, state = State.INFO, buttons = options) }
        val r = if (timeoutMs == null) choices.receive() else withTimeoutOrNull(timeoutMs) { choices.receive() }
        _ui.update { it.copy(buttons = emptyList()) }
        return r ?: fallback
    }

    private fun buzz(ms: Long) {
        val vm = ctx.getSystemService(VibratorManager::class.java) ?: return
        vm.defaultVibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    // endregion

    // region capture detection

    private fun now() = SystemClock.uptimeMillis()

    private suspend fun waitFirst(since: Long, timeoutMs: Long): SnifferLog.Capture? {
        val deadline = now() + timeoutMs
        while (now() < deadline) {
            if (aborted || skip) return null
            SnifferLog.capturesSince(since).firstOrNull()?.let { return it }
            delay(30)
        }
        return null
    }

    private suspend fun collectUntilQuiet(since: Long, quietMs: Long, maxMs: Long): List<SnifferLog.Capture> {
        val start = now()
        while (now() - start < maxMs) {
            val last = SnifferLog.lastCaptureMono() ?: 0
            if (now() - maxOf(last, start) >= quietMs) break
            delay(30)
        }
        return SnifferLog.capturesSince(since)
    }

    private suspend fun settle(quietMs: Long) {
        collectUntilQuiet(now(), quietMs, 3000)
    }

    private fun primarySteps(burst: List<SnifferLog.Capture>): List<Double> {
        val primary = if (burst.any { it.method == "broadcast.volume_changed" }) "broadcast.volume_changed" else "settings_observer"
        return burst.filter { it.method == primary }.mapNotNull { it.step127 }
    }

    private fun describe(burst: List<SnifferLog.Capture>): String {
        val parts = mutableListOf<String>()
        val steps = primarySteps(burst)
        if (steps.isNotEmpty()) parts += "volume %+.1f/127 in %d event%s".format(steps.sum(), steps.size, if (steps.size == 1) "" else "s")
        burst.filter { !it.isRelease && it.method != "broadcast.volume_changed" && it.method != "settings_observer" }
            .groupBy { it.method }
            .forEach { (m, evs) -> parts += "$m: ${evs.map { it.raw }.distinct().joinToString(", ")}" }
        return if (parts.isEmpty()) "${burst.size} events" else parts.joinToString(" · ")
    }

    // endregion

    // region trials

    private suspend fun trials(
        count: Int, timeoutMs: Long = 10_000, missLimit: Int = 3, quietMs: Long = 700,
        extra: Map<String, Any?> = emptyMap(), trial: (Int) -> Pair<String, String>,
    ): List<List<SnifferLog.Capture>> {
        val results = mutableListOf<List<SnifferLog.Capture>>()
        var misses = 0
        skip = false
        _ui.update { it.copy(skippable = true) }
        try {
            for (i in 0 until count) {
                if (aborted) break
                val (label, prompt) = trial(i)
                SnifferLog.setLabel(label)
                settle(400)
                val since = now()
                show(prompt, "${i + 1} of $count", State.WAITING)
                val first = waitFirst(since, timeoutMs)
                when {
                    first != null -> {
                        val burst = collectUntilQuiet(since, quietMs, 6000)
                        misses = 0
                        results += burst
                        val summary = describe(burst)
                        SnifferLog.write("control", "guided.trial", "detected", extra + mapOf(
                            "trial" to i + 1, "of" to count, "events" to burst.size,
                            "methods" to burst.map { it.method }.distinct().sorted(),
                            "raws" to burst.filter { !it.isRelease }.map { it.raw },
                            "step_127_total" to primarySteps(burst).sum(),
                            "reaction_ms" to (first.mono - since),
                        ))
                        show("Got it ✓", summary, State.GOT)
                        note("$label #${i + 1}: $summary")
                        buzz(30)
                        delay(700)
                    }
                    skip -> {
                        SnifferLog.write("control", "guided.trial", "skipped", extra + mapOf("trial" to i + 1, "of" to count))
                        note("$label: skipped")
                        break
                    }
                    aborted -> break
                    else -> {
                        misses++
                        SnifferLog.write("control", "guided.trial", "timeout", extra + mapOf("trial" to i + 1, "of" to count))
                        show("Nothing detected", "That's useful data too. " + if (misses < missLimit) "Let's try again." else "Moving on.", State.MISS)
                        note("$label #${i + 1}: nothing detected")
                        buzz(200)
                        delay(1500)
                        if (misses >= missLimit) {
                            SnifferLog.write("control", "guided.step", "gave_up", mapOf("label" to label, "misses" to misses))
                            break
                        }
                    }
                }
            }
        } finally {
            _ui.update { it.copy(skippable = false) }
            skip = false
        }
        return results
    }

    private suspend fun resetVolume() {
        SnifferLog.setLabel("guided_pause")
        SnifferService.instance?.resetToBaseline()
        delay(600)
        settle(300)
    }

    private fun configure(silent: Boolean = true, remote: Boolean = false, restore: Boolean = false) {
        SnifferConfig.silentAudio.value = silent
        SnifferConfig.remoteVolume.value = remote
        SnifferConfig.restore.value = restore
        SnifferLog.write("control", "guided.config", "set", mapOf("silent_audio" to silent, "remote_volume" to remote, "restore" to restore))
    }

    // endregion

    // region protocol

    suspend fun run() {
        aborted = false
        _ui.value = Ui(active = true)
        SnifferLog.write("control", "guided", "start")
        if (preflight()) {
            for ((i, title) in sections.withIndex()) {
                if (aborted) break
                sectionIndex = i
                sectionTitle = "Step ${i + 1} of ${sections.size} · $title"
                SnifferLog.write("control", "guided.section", "start", mapOf("section" to title, "index" to i + 1))
                runSection(i)
                SnifferLog.setLabel("guided_pause")
                if (aborted) break
                completed += title
                SnifferLog.write("control", "guided.section", "done", mapOf("section" to title, "index" to i + 1))
            }
        }
        configure()
        SnifferLog.setLabel("guided_end")
        SnifferLog.write("control", "guided", if (aborted) "ended_early" else "complete",
            mapOf("sections_done" to completed.toList(), "flags" to flags.toList()))
        sectionTitle = "Finished"
        show(if (aborted) "Stopped early. Results so far are saved." else "All done. Thank you!",
            "Keep the phone plugged in. Claude is pulling the results now.", State.DONE)
        buzz(300)
    }

    fun a11yEnabled(): Boolean {
        val enabled = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return enabled.contains("${ctx.packageName}/") && enabled.contains("KeyAccessibilityService")
    }

    private suspend fun preflight(): Boolean {
        sectionTitle = "Getting ready"
        var waited = 0
        while (SnifferService.instance == null && waited < 50) { delay(100); waited++ }
        val svc = SnifferService.instance ?: run {
            show("Sniffer service didn't start", "Tap Stop, then Guided test again.", State.MISS)
            return false
        }
        while (svc.bluetoothOutputs().isEmpty() && !aborted) {
            show("Connect the CMF Buds Pro 2 to this phone",
                "Open the case near the phone. This continues by itself once the buds are the audio output.", State.WAITING)
            delay(1000)
        }
        if (!a11yEnabled()) {
            val c = choose("Turn on DialSniffer in Accessibility (optional)",
                "It's one of the capture paths. Settings → Accessibility → DialSniffer → On, then come back here.",
                listOf("Open settings", "Continue without it"), null, "Continue without it")
            if (c == "Open settings") {
                SnifferLog.write("control", "guided", "open_a11y_settings")
                ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                choose("Welcome back", "Tap Continue to start the checklist.", listOf("Continue"), null, "Continue")
            }
        }
        SnifferLog.write("control", "a11y", if (a11yEnabled()) "enabled_in_settings" else "not_enabled")
        val c = choose("Ready to test the dial?", """
            • Disconnect the buds from your Mac (Mac: Control Center → Bluetooth → CMF Buds Pro 2 → off)
            • Nothing X: dial on, rotate = volume
            • No music or video playing
            • Hands off the dial until a step asks for it
            Output: ${svc.bluetoothOutputs().joinToString()} · volume ${svc.musicVolume()}/${svc.musicMax()}
            About 10–15 minutes. Most important steps come first.
        """.trimIndent(), listOf("Start", "Cancel"), null, "Start")
        if (c == "Cancel") { aborted = true; return false }
        configure()
        return true
    }

    private suspend fun idleDrift() {
        resetVolume()
        SnifferLog.setLabel("idle_drift")
        val since = now()
        for (left in 30 downTo 1) {
            if (aborted) return
            show("Put the case down and don't touch the dial", "Checking that the volume stays put on its own… ${left}s", State.WAITING)
            delay(1000)
        }
        val drift = SnifferLog.capturesSince(since).filter { it.method == "broadcast.volume_changed" || it.method == "settings_observer" }
        val net = drift.filter { it.method == "broadcast.volume_changed" }.mapNotNull { it.step127 }.sum()
        SnifferLog.write("control", "guided.idle_result", if (drift.isEmpty()) "stable" else "drift",
            mapOf("events" to drift.size, "step_127_total" to net, "seconds" to 30))
        if (drift.isEmpty()) {
            show("Volume is stable ✓", "No changes in 30 seconds.", State.GOT)
        } else {
            flags += "volume changed during the idle check"
            show("Volume changed during the check", "%d changes, net %+.1f/127. Logged; continuing.".format(drift.size, net), State.MISS)
        }
        note("idle: ${if (drift.isEmpty()) "stable" else "changed (${drift.size})"}")
        delay(2000)
    }

    private suspend fun presses(label: String, prompt: String, count: Int, missLimit: Int, timeoutMs: Long = 10_000, blocker: Boolean = false) {
        val r = trials(count, timeoutMs, missLimit, quietMs = 1000) { label to prompt }
        if (blocker && r.isEmpty() && !aborted) flags += "no $label events reached the phone"
    }

    private suspend fun rotations() {
        resetVolume()
        val bursts = trials(20, missLimit = 4, quietMs = 600) { i ->
            if (i % 2 == 0) "rotate_cw" to "Turn the dial RIGHT one click" else "rotate_ccw" to "Turn the dial LEFT one click"
        }
        val perClick = bursts.map { abs(primarySteps(it).sum()) }.filter { it > 0 }.sorted()
        if (perClick.isNotEmpty()) {
            stepSize127 = perClick[perClick.size / 2]
            SnifferLog.write("control", "guided.step_size", "measured", mapOf("step_127" to stepSize127))
        }
    }

    private val spinClicks: Int
        get() = stepSize127?.takeIf { it > 0 }?.let { (50 / it).toInt().coerceIn(3, 10) } ?: 10

    private suspend fun fastSpins() {
        val n = spinClicks
        SnifferLog.write("control", "guided.fast_clicks", "$n", mapOf("clicks" to n))
        for (i in 0 until 6) {
            if (aborted || skip) break
            resetVolume()
            val right = i % 2 == 0
            trials(1, timeoutMs = 15_000, missLimit = 1, quietMs = 900, extra = mapOf("instructed_clicks" to n)) {
                (if (right) "fast_cw" else "fast_ccw") to "Spin ${if (right) "RIGHT" else "LEFT"} FAST: exactly $n clicks\n(spin ${i / 2 + 1} of 3)"
            }
        }
    }

    private suspend fun remoteProvider() {
        resetVolume()
        configure(remote = true)
        delay(500)
        trials(6, missLimit = 3, quietMs = 700) { i ->
            if (i % 2 == 0) "rotate_cw_remote" to "Turn RIGHT one click\n(testing the VolumeProvider path)"
            else "rotate_ccw_remote" to "Turn LEFT one click\n(testing the VolumeProvider path)"
        }
        configure()
    }

    private suspend fun restoreTest() {
        resetVolume()
        configure(restore = true)
        trials(10, missLimit = 3, quietMs = 700) { i ->
            if (i % 2 == 0) "rotate_cw_restore" to "Turn RIGHT one click" else "rotate_ccw_restore" to "Turn LEFT one click"
        }
        trials(2, timeoutMs = 15_000, missLimit = 1, quietMs = 900, extra = mapOf("instructed_clicks" to 10)) { i ->
            "fast_cw_restore" to "Spin RIGHT FAST: about 10 clicks (${i + 1} of 2)"
        }
        val blips = choose("Did you hear clicks, pops or dropouts in the buds just now?",
            "The volume was being snapped back after every click.", listOf("Yes, blips", "No, silent", "Not sure"), 90_000, "Not sure")
        SnifferLog.write("control", "guided.blips", blips)
        configure()
        resetVolume()
    }

    private suspend fun silentOff() {
        configure(silent = false)
        trials(5, missLimit = 2, quietMs = 1000) { "press_single_nosilent" to "Press the dial ONCE now\n(silent audio is off)" }
        configure()
    }

    private suspend fun competingApp() {
        val c = choose("Last one (optional): play music in Spotify or YouTube",
            "Start something playing, come back here, then tap Ready. This tests whether another app steals the presses.",
            listOf("Ready", "Skip"), 180_000, "Skip")
        SnifferLog.write("control", "guided.competing_app", c)
        if (c != "Ready") return
        trials(5, missLimit = 2, quietMs = 1000) { "press_single_competing" to "Press the dial ONCE now\n(with the other app playing)" }
        choose("Done. You can pause the other app now.", "", listOf("OK"), 30_000, "OK")
    }

    // endregion
}
