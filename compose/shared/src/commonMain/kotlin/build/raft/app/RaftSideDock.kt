package build.raft.app

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
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

/** The status bar's clock, Wi-Fi and battery sit at the top of the strip. */
internal val RaftSideDockStatusClearance = 104.dp

internal fun raftSideDockActive(navRailActive: Boolean, rightSafeArea: Dp): Boolean =
    navRailActive && rightSafeArea >= RaftSideDockMinStrip

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
    onBack: () -> Unit,
    searchLabel: String,
    onSearch: () -> Unit,
    bottomSafeArea: Dp,
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
                    .padding(top = RaftSideDockStatusClearance, bottom = RaftAppRailDefaults.Inset + bottomSafeArea, end = RaftSideDockEndNudge),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(RaftAppRailDefaults.ItemGap),
            ) {
                CompositionLocalProvider(LocalRaftContentColor provides colors.foregroundOnFrame) {
                    if (currentServer != null) {
                        // The top bar's workspace button: opens the server panel.
                        Box(
                            Modifier
                                .size(RaftAppRailDefaults.ItemSize)
                                .clickable(onClickLabel = currentServer.name, onClick = onServerClick),
                            contentAlignment = Alignment.Center,
                        ) {
                            ServerSwitcherAvatarTile(currentServer, size = RaftSideDockServerAvatar)
                        }
                    }
                    topItems.forEach { RaftNavigationRailTabItem(item = it, onSelect = onSelect) }
                    Box(Modifier.width(RaftAppRailDefaults.ItemSize).height(RaftStroke.Hairline).background(colors.lineSeam))
                    items.forEach { RaftNavigationRailTabItem(item = it, onSelect = onSelect) }
                    Spacer(Modifier.weight(1f))
                    RaftSideDockAction(RaftLucideIconName.ArrowLeft, backLabel, enabled = canGoBack, onClick = onBack)
                    RaftSideDockAction(RaftLucideIconName.Search, searchLabel, enabled = true, onClick = onSearch)
                }
            }
        }
    }
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
