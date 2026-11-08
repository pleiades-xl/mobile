package build.raft.app

import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.NativeClipboard
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue

/**
 * Self-build (xuheng-li, runzhou-tao 2026-11-08): Paste in the composer with only an image on the
 * clipboard attaches the image, as other messengers do. The text menu offers Paste only for text,
 * so the composer's clipboard reports this marker then; pasting it triggers the image paste.
 */
internal const val RaftImagePasteMarker = "raft-paste-image"

/** The marker entry while the clipboard holds an image and no text (iOS); null elsewhere. */
internal expect fun raftImagePasteClipEntry(): ClipEntry?

internal class RaftImagePasteClipboard(private val delegate: Clipboard) : Clipboard {
    override suspend fun getClipEntry(): ClipEntry? = raftImagePasteClipEntry() ?: delegate.getClipEntry()

    override suspend fun setClipEntry(clipEntry: ClipEntry?) = delegate.setClipEntry(clipEntry)

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override val nativeClipboard: NativeClipboard
        get() = delegate.nativeClipboard
}

/** [this] without the paste marker, the caret where it was. */
internal fun TextFieldValue.withoutImagePasteMarker(): TextFieldValue {
    val at = text.indexOf(RaftImagePasteMarker)
    if (at < 0) return this
    return TextFieldValue(text.replace(RaftImagePasteMarker, ""), TextRange(at))
}
