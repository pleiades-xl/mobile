package build.raft.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * Self-build: a conversation handed to the shell while pages cover it. The pages over the shell
 * close ([base.BasePager]); the shell, once on top, opens it (RaftAppShellReadyContent).
 *
 * - Unfold (xuheng-li 2026-10-30): a conversation pushed on a narrow window (iPhone Duo's outer
 *   screen) moves into the wide layout's detail pane when the window goes wide ([waitForWide]).
 * - Notification and message-link opens (2026-10-31): the conversation replaces the pages over
 *   the shell instead of stacking one more page per tap.
 */
internal object RaftWideHandoff {
    var pending by mutableStateOf<WireThreadLaunchPayload?>(null)
        private set
    private var requestedAt: TimeMark? = null

    /** The shell waits for the wide layout before it falls back to pushing the page again. */
    var waitForWide = false
        private set

    /** Pages over the shell close while this holds; a request older than 5 s no longer acts. */
    val closesPages: Boolean
        get() = pending != null && (requestedAt?.elapsedNow()?.inWholeMilliseconds ?: 0L) < 5_000L

    /** The first request wins: a page under the one that asked must not replace its conversation. */
    fun request(payload: WireThreadLaunchPayload, waitForWide: Boolean): Boolean {
        if (closesPages) return false
        this.waitForWide = waitForWide
        pending = payload
        requestedAt = TimeSource.Monotonic.markNow()
        return true
    }

    fun clear() {
        pending = null
        requestedAt = null
    }
}
