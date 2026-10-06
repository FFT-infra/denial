/// Semantic state-change requests understood by Denial's window action bridge.
///
/// This is a shared vocabulary, not a command transport. A shell runtime must
/// route actions to the authoritative controller. No action runs on import.
enum DenialWindowAction {
  minimize,
  maximize,
  fullscreen,
  restore,
  toggleMaximize,
  toggleFullscreen,
}
