package build.raft.app

/** Self-build: the iOS host calls this when the editor's system paste finds only an image. */
fun raftRequestImagePaste() {
    RaftImagePasteRequests.count++
}
