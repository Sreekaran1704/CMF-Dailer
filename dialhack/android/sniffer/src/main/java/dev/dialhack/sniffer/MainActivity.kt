package dev.dialhack.sniffer

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val notifPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
    private val guided by lazy { GuidedRunner(applicationContext) }
    private var guidedJob: Job? = null

    /** Also reachable over adb: `am start -n dev.dialhack.sniffer/.MainActivity --ez guided true`. */
    private fun startGuided() {
        if (guidedJob?.isActive == true) return
        ContextCompat.startForegroundService(this, Intent(this, SnifferService::class.java))
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        guidedJob = lifecycleScope.launch {
            guided.run()
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("guided", false)) startGuided()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SnifferLog.init(this)
        if (Build.VERSION.SDK_INT >= 33) notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        if (intent.getBooleanExtra("guided", false)) startGuided()
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    val g by guided.ui.collectAsState()
                    if (g.active) {
                        GuidedScreen(g, onButton = guided::press, onClose = {
                            guided.aborted = true
                            guidedJob?.cancel()
                            SnifferLog.write("control", "guided", "ended_early", mapOf("reason" to "closed"))
                        })
                        return@Surface
                    }
                    SnifferScreen(
                        onGuided = { startGuided() },
                        onStart = { ContextCompat.startForegroundService(this, Intent(this, SnifferService::class.java)) },
                        onStop = { stopService(Intent(this, SnifferService::class.java)) },
                        onA11y = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                        onExport = { export() },
                        logPath = SnifferLog.file()?.absolutePath ?: "?",
                    )
                }
            }
        }
    }

    /** Extra observation point: keys delivered to our window while the app is in the foreground. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (SnifferLog.isMediaOrVolumeKey(event.keyCode)) SnifferLog.key("activity.dispatchKeyEvent", event)
        return super.dispatchKeyEvent(event)
    }

    private fun export() {
        val file = SnifferLog.file() ?: return
        if (!file.exists()) return
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType("application/json")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(send, "Export sniffer log"))
    }
}

private val labels = listOf(
    "idle", "rotate_cw", "rotate_ccw", "fast_cw",
    "press_single", "press_double", "press_triple", "press_long",
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SnifferScreen(
    onGuided: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onA11y: () -> Unit,
    onExport: () -> Unit,
    logPath: String,
) {
    val running by SnifferConfig.serviceRunning.collectAsState()
    val label by SnifferLog.label.collectAsState()
    val recent by SnifferLog.recent.collectAsState()

    Column(Modifier.safeDrawingPadding().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = onGuided, modifier = Modifier.fillMaxWidth().height(56.dp)) { Text("Guided test", fontSize = 18.sp) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = if (running) onStop else onStart) { Text(if (running) "Stop service" else "Start service") }
            OutlinedButton(onClick = onA11y) { Text("Accessibility…") }
            OutlinedButton(onClick = onExport) { Text("Export") }
        }
        Toggle("Silent audio + audio focus", SnifferConfig.silentAudio)
        Toggle("Remote VolumeProvider (path B)", SnifferConfig.remoteVolume)
        Toggle("Restore volume to baseline", SnifferConfig.restore)

        Text("Label", style = MaterialTheme.typography.labelLarge)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            labels.forEach { l ->
                FilterChip(selected = l == label, onClick = { SnifferLog.setLabel(l) }, label = { Text(l) })
            }
        }

        // Logged on touch-down (not release) so it's a usable latency reference.
        Box(
            Modifier
                .fillMaxWidth()
                .height(72.dp)
                .background(Color(0xFF3B5BDB), MaterialTheme.shapes.medium)
                .pointerInput(Unit) {
                    detectTapGestures(onPress = { SnifferLog.write("marker", "marker.touch", "MARK") })
                },
            contentAlignment = Alignment.Center,
        ) { Text("MARK (tap with each gesture)", color = Color.White) }

        Text(logPath, fontSize = 10.sp, fontFamily = FontFamily.Monospace)

        LazyColumn(Modifier.fillMaxSize()) {
            items(recent) { e ->
                Text(
                    "${e.mono} ${e.kind.take(4)} ${e.method} ${e.raw} ${e.detail}",
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = when (e.kind) {
                        "capture" -> Color(0xFFB2F2BB)
                        "self" -> Color(0xFF868E96)
                        "marker" -> Color(0xFF91A7FF)
                        else -> Color(0xFFDEE2E6)
                    },
                )
            }
        }
    }
}

@Composable
private fun Toggle(text: String, state: MutableStateFlow<Boolean>) {
    val on by state.collectAsState()
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text, Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = { state.value = it })
    }
}

@Composable
private fun GuidedScreen(g: GuidedRunner.Ui, onButton: (String) -> Unit, onClose: () -> Unit) {
    val tint = when (g.state) {
        GuidedRunner.State.WAITING -> Color(0xFF1C3B6E)
        GuidedRunner.State.GOT, GuidedRunner.State.DONE -> Color(0xFF1E4D2B)
        GuidedRunner.State.MISS -> Color(0xFF5C3A12)
        GuidedRunner.State.INFO -> Color(0xFF1F1F1F)
    }
    Column(
        Modifier.fillMaxSize().background(tint).safeDrawingPadding().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(g.section, color = Color(0xFFADB5BD), modifier = Modifier.weight(1f))
            OutlinedButton(onClick = onClose) { Text(if (g.state == GuidedRunner.State.DONE) "Close" else "Stop") }
        }
        androidx.compose.material3.LinearProgressIndicator(progress = { g.progress }, modifier = Modifier.fillMaxWidth())
        Text(g.prompt, fontSize = 30.sp, lineHeight = 36.sp, color = Color.White)
        if (g.detail.isNotEmpty()) Text(g.detail, fontSize = 15.sp, color = Color(0xFFCED4DA))
        g.buttons.forEach { b ->
            Button(onClick = { onButton(b) }, modifier = Modifier.fillMaxWidth().height(56.dp)) { Text(b, fontSize = 18.sp) }
        }
        if (g.skippable) OutlinedButton(onClick = { onButton("__skip") }) { Text("Skip this gesture") }
        Spacer(Modifier.weight(1f))
        g.notes.forEach { Text(it, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = Color(0xFFADB5BD), maxLines = 1) }
    }
}
