package build.raft.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Self-build (xuheng-li 2026-10-30): a conversation pushed over the shell on a narrow window (iPhone
 * Duo's outer screen) moves into the wide layout's detail pane when the window goes wide, instead
 * of staying full screen until the user backs out to the shell. The pushed page hands its launch
 * payload over and closes; the pages under it close as they reappear ([base.BasePager]); the
 * shell, once on top and wide, opens it (RaftAppShellReadyContent).
 */
internal object RaftWideHandoff {
    var pending by mutableStateOf<WireThreadLaunchPayload?>(null)
        private set
    private var requestedAt: TimeMark? = null

    /** Pages over the shell close while this holds; a request older than 5 s no longer acts. */
    val closesPages: Boolean
        get() = pending != null && (requestedAt?.elapsedNow()?.inWholeMilliseconds ?: 0L) < 5_000L

    /** The first request wins: a page under the one that asked must not replace its conversation. */
    fun request(payload: WireThreadLaunchPayload): Boolean {
        if (closesPages) return false
        pending = payload
        requestedAt = TimeSource.Monotonic.markNow()
        return true
    }

    fun clear() {
        pending = null
        requestedAt = null
    }
}
