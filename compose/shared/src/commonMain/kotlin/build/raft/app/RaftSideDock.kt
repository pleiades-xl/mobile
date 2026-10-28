package build.raft.app

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import build.raft.app.components.RaftDesignSystemTheme
import build.raft.designsystem.components.RaftAppRailDefaults
import build.raft.designsystem.components.RaftAppRailItem
import build.raft.designsystem.components.raftConsumeSafeAreaHorizontal
import build.raft.designsystem.theme.LocalRaftContentColor
import build.raft.designsystem.theme.RaftTheme
import build.raft.designsystem.tokens.RaftStroke

/*
 * iPhone Duo landscape (xuheng-li 2026-10-28): iOS puts the status bar in a strip down the right
 * edge and leaves the rest of the strip empty. The wide layout's top bar and left rail move into
 * that strip: the server, Settings, the rail's destinations, then Back and Search at the foot.
 */

/** Set by the app shell; a conversation header in the split detail drops its Back while it is on. */
internal object RaftSideDockState {
    var active by mutableStateOf(false)

    /**
     * The shell's dock, for a page pushed over the shell to draw too ([RaftPushedPageDockFrame]).
     * The page passes `leavePage`, run before each action to go back to the shell; the shell null.
     */
    var pushedPageDock: (@Composable (leavePage: (() -> Unit)?, width: Dp) -> Unit)? by mutableStateOf(null)
}

/** The right strip is at least this wide: the dock goes there. */
private val RaftSideDockMinStrip = 44.dp

private val RaftSideDockServerAvatar = 32.dp

/**
 * The status bar's icons are centred about 6dp left of the strip's centre (measured on an iPhone
 * Duo); the dock's items line up under them.
 */
private val RaftSideDockEndNudge = 12.dp

/** The inner display's rounded top-left corner: the panes start this much lower. */
internal val RaftSideDockCornerClearance = 12.dp

/** The status bar's clock, Wi-Fi and battery sit at the top of the strip (inner display). */
internal val RaftSideDockStatusClearance = 104.dp

/** The outer display's status icons sit lower, under the phone layout's header. */
internal val RaftSideDockPhoneStatusClearance = 160.dp

/**
 * The outer display (phone layout) puts the system tab bar on the same strip, where its taps never
 * reach the app; the dock replaces it there.
 */
internal fun raftPhoneSideDockActive(navRailActive: Boolean, safeArea: RaftHorizontalSafeArea): Boolean =
    !navRailActive && raftSideDockStrip(safeArea)

internal fun raftSideDockActive(navRailActive: Boolean, safeArea: RaftHorizontalSafeArea): Boolean =
    navRailActive && raftSideDockStrip(safeArea)

/** A strip on the right only (iPhone Duo); a phone in landscape has one on each side. */
internal fun raftSideDockStrip(safeArea: RaftHorizontalSafeArea): Boolean =
    safeArea.right >= RaftSideDockMinStrip && safeArea.left < RaftSideDockMinStrip / 2

/** The log tag the iOS host listens for to open the share sheet with the log files. */
internal const val RaftShareLogsTag = "RaftShareLogs"

/** The log tag the iOS host listens for to pop the pushed pages back to the app shell. */
private const val RaftPopToShellTag = "RaftPopToShell"

/**
 * A page pushed over the app shell keeps the shell's dock in the strip (xuheng-li 2026-10-28);
 * a dock action pops back to the shell first. Same nodes whether or not the dock shows, so a
 * fold or a rotation keeps the page's state.
 */
@Composable
internal fun RaftPushedPageDockFrame(enabled: Boolean, content: @Composable () -> Unit) {
    val safeArea = if (enabled) raftHorizontalSafeArea() else RaftHorizontalSafeArea.Zero
    val dock = RaftSideDockState.pushedPageDock?.takeIf { raftSideDockStrip(safeArea) }
    Row(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .weight(1f)
                .fillMaxHeight()
                .then(if (dock != null) Modifier.raftConsumeSafeAreaHorizontal(WindowInsetsSides.End) else Modifier)
        ) {
            content()
        }
        dock?.invoke({ raftLogInfo(RaftPopToShellTag, "pop_to_shell") }, safeArea.right)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun RaftSideDock(
    width: Dp,
    currentServer: RaftServerSwitcherItem?,
    onServerClick: () -> Unit,
    topItems: List<RaftBottomTabItemPayload>,
    items: List<RaftBottomTabItemPayload>,
    onSelect: (String) -> Unit,
    backLabel: String,
    canGoBack: Boolean,
    /** Null draws no Back (the phone layout's pages have their own). */
    onBack: (() -> Unit)?,
    searchLabel: String,
    onSearch: () -> Unit,
    bottomSafeArea: Dp,
    statusClearance: Dp = RaftSideDockStatusClearance,
    /** The phone layout's Search is a tab: drawn at the foot as one, instead of [onSearch]. */
    footerItems: List<RaftBottomTabItemPayload> = emptyList(),
) {
    RaftDesignSystemTheme {
        val colors = RaftTheme.colors
        Row(Modifier.fillMaxHeight()) {
            Box(Modifier.width(RaftStroke.Hairline).fillMaxHeight().background(colors.lineSeam))
            Column(
                Modifier
                    .fillMaxHeight()
                    .width(width)
                    .background(colors.layerFrame)
                    .padding(top = statusClearance, bottom = RaftAppRailDefaults.Inset + bottomSafeArea, end = RaftSideDockEndNudge),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(RaftAppRailDefaults.ItemGap),
            ) {
                CompositionLocalProvider(LocalRaftContentColor provides colors.foregroundOnFrame) {
                    // Bottom-aligned: the status bar above grows when the Dynamic Island shows something.
                    Spacer(Modifier.weight(1f))
                    if (currentServer != null) {
                        // The top bar's workspace button: opens the server panel.
                        Box(
                            Modifier
                                .size(RaftAppRailDefaults.ItemSize)
                                .combinedClickable(
                                    onClickLabel = currentServer.name,
                                    // Self-build: a long press shares the diagnostics log files (iOS).
                                    onLongClick = { raftLogInfo(RaftShareLogsTag, "share_logs_request") },
                                    onClick = onServerClick,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            ServerSwitcherAvatarTile(currentServer, size = RaftSideDockServerAvatar)
                        }
                    }
                    if (topItems.isNotEmpty()) {
                        topItems.forEach { RaftNavigationRailTabItem(item = it, onSelect = onSelect) }
                        RaftSideDockSeam()
                    }
                    items.forEach { RaftNavigationRailTabItem(item = it, onSelect = onSelect) }
                    RaftSideDockSeam()
                    if (onBack != null) {
                        RaftSideDockAction(RaftLucideIconName.ArrowLeft, backLabel, enabled = canGoBack, onClick = onBack)
                    }
                    if (footerItems.isEmpty()) {
                        RaftSideDockAction(RaftLucideIconName.Search, searchLabel, enabled = true, onClick = onSearch)
                    } else {
                        footerItems.forEach { RaftNavigationRailTabItem(item = it, onSelect = onSelect) }
                    }
                }
            }
        }
    }
}

@Composable
private fun RaftSideDockSeam() {
    Box(Modifier.width(RaftAppRailDefaults.ItemSize).height(RaftStroke.Hairline).background(RaftTheme.colors.lineSeam))
}

@Composable
private fun RaftSideDockAction(icon: RaftLucideIconName, label: String, enabled: Boolean, onClick: () -> Unit) {
    RaftAppRailItem(
        label = label,
        selected = false,
        onClick = onClick,
        enabled = enabled,
        icon = { ink ->
            RaftLucideIcon(name = icon, color = raftArgbHex(ink), modifier = Modifier.size(RaftAppRailDefaults.IconSize))
        },
    )
}
