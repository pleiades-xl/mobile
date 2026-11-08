package build.raft.app

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.ClipEntry
import platform.UIKit.UIPasteboard

@OptIn(ExperimentalComposeUiApi::class)
internal actual fun raftImagePasteClipEntry(): ClipEntry? {
    val board = UIPasteboard.generalPasteboard
    return if (board.hasImages && !board.hasStrings) ClipEntry.withPlainText(RaftImagePasteMarker) else null
}
