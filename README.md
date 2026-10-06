# Midoku

A native **macOS manga reader**, built with AppKit and SwiftUI. The desktop app
uses separate library and reader windows, adaptive shelf layouts, mouse panning
and zoom, direction-aware keyboard navigation, and customizable shortcuts.

Open [Midoku.xcodeproj](Midoku.xcodeproj) in **Xcode 16+** and run the **Midoku**
scheme on **My Mac**. Requires **macOS 14+**. This target does not use Mac Catalyst.

The current native implementation supports CBZ/ZIP, PDF and image-folder import,
modern Aidoku repository/source installation, source browsing/search, chapter
reading with on-demand image caching, local collections and favorites, saved
reading progress, single/double/continuous reading, and English/Simplified Chinese UI. See [desktop development and validation
instructions](Desktop/README.md) for controls, build commands and architecture.

The native target supports modern Aidoku ABI 0.7 WASM sources; legacy source
formats are excluded. Trackers, background download queues, dictionaries,
iCloud, built-in server clients, RAR/CBR and old library migration remain
unimplemented. Advanced OAuth/custom-setting support is also outstanding.
Original files under `Aidoku/` remain for porting and are not linked into the desktop app. Linux validation covers the
portable core; macOS app compilation and interactive checks remain outstanding.

Midoku is derived from [Aidoku](https://github.com/Aidoku/Aidoku). Original project
documentation is retained in [docs/Aidoku-legacy.md](docs/Aidoku-legacy.md).
The original GPLv3 license and attribution remain in place; see [LICENSE](LICENSE).
