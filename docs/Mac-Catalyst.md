# Midoku on Mac Catalyst

The Mac target uses the original Aidoku UIKit/SwiftUI interface and services. It requires **macOS 15 or later**: the pinned dictionary dependency targets Catalyst 18. Open `Midoku.xcodeproj`, select the **Midoku** scheme and **My Mac (Mac Catalyst)** destination. Select your development team for a signed application. iOS retains its original deployment target and presentation flow.

## Windows

The main window starts on Library and retains Browse, Search, History, manga details, source management, downloads, trackers, dictionaries, backups and settings. Those features keep their existing navigation and sheets.

Library, manga details, History, downloaded chapters and vocabulary source links open a separate reader window. The first Mac version reuses one reader window. Opening another chapter saves and ends the previous reader session before installing the new reader. Opening the same chapter activates the current window without resetting its position. Explicit vocabulary page links jump to the requested page.

The reader retains Aidoku’s paged, double-page, vertical, webtoon and text readers, chapter lists, reading settings, image processing and lookup panels. Closing it saves progress and releases temporary pages; the main window remains available. Closing the main window leaves a reader open; Command-1 reopens Library. Window restoration stores manga/chapter identity, source ID and page; continuous positions continue using the existing history database.

The main and reader scenes use the same Core Data stores and managers. Progress changes retain the existing notifications used by the shelf and history. Toolbars and scene activation events are scoped to their reader.

## Desktop controls

| Action | Input |
| --- | --- |
| Library / Browse / History | Command-1 / Command-2 / Command-3 |
| Application settings | Command-comma |
| Search the library | Command-F |
| Refresh the library | Command-R |
| Visual left / right page | Left / Right arrows |
| Logical previous / next page | A / D, Page Up / Page Down |
| Reader controls | Q or Space; center click |
| Chapter list | Command-L |
| Reading settings | R |
| Close the reader | Command-W or Escape |
| Image zoom | Command-plus / Command-minus; existing pinch and double-click gestures |

Tab remains available for native focus traversal. Reader shortcuts yield to text entry, focused controls and presented sheets. Original chapter shortcuts (comma / period) and page-offset shortcut O remain available.

Clicks preserve Aidoku’s configurable tap regions and dictionary lookup priority. New Mac installations default to left/right tap regions; existing saved preferences are preserved. Mouse dragging turns fitted pages after a 60-point movement, with native image panning retained when zoomed. Vertical readers use vertical dragging. Dragging cancels click recognition. Existing context menus remain available through right-click. Library/source multi-selection requires entering Edit mode, so an ordinary mouse click opens the item.

Discrete mouse-wheel gestures turn fitted pages immediately. Continuous trackpad gestures use a threshold and turn at most one page per gesture. Long images scroll within the image; a new outward gesture at an edge can turn a page. Zoomed images keep scrolling ownership. Webtoon and scrolling text modes use their original scroll views. Full screen is managed by the standard Mac window controls/menu.

### Sliding double pages

On Mac, horizontal double-page reading advances one page at a time: `1–2 → 2–3 → 3–4`. Both explicit Double and landscape Auto layouts use this behavior. Keyboard, tap regions, mouse dragging and scroll gestures share the same navigation path. Horizontal trackpad gestures also move one page at a time.

With page-transition animations enabled, three page slots slide together by half the window width over 0.3 seconds: the outgoing page leaves, the retained page moves to the first reading position, and the incoming page enters the second position. Right-to-left reading reverses the movement. The retained page controller and image are reused; transition snapshots prevent overlapping spreads from moving the shared view prematurely. Each page fits within a fixed half-width slot. The existing animation setting and macOS Reduce Motion preference are respected.

Cover offsets, isolated wide images and chapter boundary screens keep their existing roles. The final pair advances to the chapter boundary without showing its last page again as a duplicate single-page stop. iOS and vertical readers retain their original spread behavior.

`ReaderSlidingSpreadTests` exercises both reading directions, retained-page identity, progress without prefetching, cover offsets, chapter boundaries, adjacent-chapter navigation and half-width translation. The Catalyst suite passed 44 tests in 10 suites; a six-page numbered CBZ was also used to check the visible pairs and keyboard, wheel, mouse-drag and tap navigation.

## Dependencies and capabilities

`Vendor/Texture` contains the pinned Texture 3.1.1 sources and license. Its local Swift package builds for iOS and Catalyst instead of using the upstream iOS-only binary. The local changes are documented in its README.

Catalyst uses its own scene manifest and sandbox entitlements. Network access and user-selected read/write files are enabled; imports retain their original security-scoped access handling. iCloud and push capabilities require a matching application identifier, provisioned entitlements and developer team. Merely building does not verify these services.

Downloads and manual library refresh keep the existing workers. The iOS-only continued-background-processing API is excluded on Catalyst; desktop workers run while the app is running. Existing scheduled backup/library-refresh behavior is retained and needs service-level validation on Mac.

## Validation

Compile without signing:

```sh
xcodebuild -project Midoku.xcodeproj -scheme Midoku -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/Catalyst -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

Run the Midoku tests on the Catalyst destination with your signing configuration. `ReaderDesktopTests` checks source identity and chapter order through restoration, invalid activities, one-page-per-gesture limits, immediate wheel turns and long-image edge ownership.

Before the project rename, validation on October 6, 2026 used Xcode 27.1 on macOS 27.2. The Catalyst application and the iOS Simulator target built successfully. The Catalyst test suite passed 39 tests across 9 suites. UI checks used a separate `app.aidoku.MidokuValidation` bundle identifier and a generated five-page CBZ fixture. Confirmed behaviors include local CBZ import, manga-detail reading, A/D navigation, Command-L chapter lists, mouse dragging, wheel navigation in both directions, Command-W closing only the active window, and Command-1 recreating Library while the reader remains open.

The [Aidoku Community Sources list](https://aidoku-community.github.io/sources/index.min.json) loaded through the original source manager. The installed CopyManga v23 source loaded its homepage, manga details, chapter list and chapter images in the separate reader. Manhuagui did not finish its listing during the UI check; source availability and authenticated services still require individual verification.

Before release, check main/reader resizing, every reading entry point, close/reopen and restored progress, RTL/LTR input, double-click versus single-click, drag cancellation, long-image scrolling, trackpad inertia, text-field and sheet focus, live text/dictionary interactions, authenticated sources, trackers, download queues, scheduled tasks and iCloud with a provisioned account. A compilation or policy test does not establish those runtime results.

## Project identity

The application, Xcode project, scheme, test module and source directories are named Midoku. The default application identifier is `app.midoku.Midoku`. Midoku is based on [Aidoku](https://github.com/Aidoku/Aidoku); its authorship and licenses remain intact.

Rename validation confirmed the Midoku/MidokuTests targets and Midoku scheme, Debug/Release file references, localized application names, packaging metadata and Swift syntax. The post-rename build could not resolve package manifests because the validation sandbox denied writes to SwiftPM’s user cache; the earlier successful build and test results above precede this rename. Build the renamed project in Xcode to verify the new product.

The `midoku://` URL scheme is available alongside the compatible `aidoku://` scheme. AidokuRunner, source/backup type identifiers, legacy WASM imports and image URL schemes remain compatible with the Aidoku ecosystem. The Core Data model bundle is named Midoku, while existing SQLite filenames and cache identifiers are retained to avoid losing data within an existing container. An application identifier change creates a separate app container; an existing Aidoku library can be transferred using its backup/import feature.
