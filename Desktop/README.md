# Midoku for macOS

The app uses AppKit and SwiftUI directly, requires **macOS 14+**, and has separate
library, source browser, manga details, website and reader windows. Open
**Midoku.xcodeproj**, select **Midoku**, and run on **My Mac** in **Xcode 16+**.
Select a development team to run a signed sandboxed build.

## Read from Aidoku sources

1. Choose **File → Sources**, then **Manage Sources**.
2. Add a repository base URL, its explicit `index.min.json` / `index.json` URL,
   or an `aidoku://add-source-list?url=…` link. Base URLs resolve to
   `index.min.json`, following Aidoku's convention. No repository is preinstalled.
3. Install a source from the repository. Select it in the source sidebar.
4. Browse its home/listings or search; use Search Filters for genre, sort,
   inclusion/exclusion, text and numeric ranges. Open a cover for manga details.
5. Select a chapter to open an independent reader. The chapter is retained on
   the shelf with reading progress. The reader's Chapters button returns to the
   series. Source-provided reading direction/webtoon layout is used initially.

**Only modern Aidoku repositories and ABI 0.7 WASM sources are supported.** The
native app does not load the legacy ABI 0.6 runtime or array-shaped legacy
indexes. A modern index uses a `name` and `sources` object; entries require
`id`, `name`, `version` and `downloadURL`, with optional `languages`, `iconURL`,
`contentRating` and `sha256`. Downloads resolve relative to the final index URL.
Source `.aix` archives contain `Payload/source.json` and `Payload/main.wasm`.
Packages are bounded, path-validated, checked by CRC32 and, when supplied,
SHA-256. Installation verifies manifest identity/version and initializes the
runtime before atomically replacing the installed source. Refresh, update,
uninstall and repository removal are available in the manager.

Source Settings exposes source-defined language/base URL and common preferences.
The website window uses a separate persistent WebKit store per source. Complete
Sign In forwards web-login cookies to the runner. Basic login saves credentials
in macOS Keychain and exposes the fields expected
by the runner through a volatile preferences domain. Basic-login passwords stay out of
the library JSON and preferences plist. Sign Out clears the login record.
OAuth callbacks, custom setting widgets and web login requiring localStorage
are not implemented yet. Sign-in/verification availability depends on the site.
The website and HTTP client use matching user agents; HTTP requests import and
save cookies within the source's namespace, keeping global HTTP cookie storage
disabled. Sources retain their custom requests, headers and image processing.
HTTP sites are permitted through ATS to match Aidoku source behavior; HTTPS
certificate validation remains enabled.

URL, embedded-image and ZIP-image pages are decoded on demand; non-image text
pages show an unsupported-page error. Pages are atomically cached on disk, and
failed requests can be retried. Fully cached chapters open without contacting a
source. Partial chapters refresh their page descriptors after restarting; if
that fails, Read Cached Pages allows access to pages already on disk. This is
an on-demand reading cache, with no background chapter-download queue or cache
quota interface. Removing a chapter deletes its stored pages. Uninstalling a
source preserves chapter records and cached images.

## Desktop controls

- Import CBZ/ZIP, PDF, individual images or image folders with ⌘O, or drop files
  on the shelf. Imports own copies; PDFs are rasterized to images.
- The adaptive shelf supports search, sorting, collections, favorites and an
  inspector. Click selects; ⌘-click toggles; Shift-click selects a range.
  Arrows navigate the grid, Return or double-click opens the reader.
- Different chapters/books have independent, resizable reader windows. Closing
  one leaves the library and other readers open.
- Single pages, spreads with optional single cover, and continuous reading are
  available. Explicit edge buttons turn pages. Drag zoomed pages to pan;
  double-click toggles actual size/fit at the clicked point. Wheel scrolls,
  ⌘-wheel and pinch zoom in the AppKit canvas.
- ←/→ follow reading direction; Space advances, Shift-Space goes back. Settings
  → Keyboard records shortcuts, validates conflicts and saves assignments.
  Search fields, sheets and Settings retain normal macOS text input shortcuts.

## Architecture and dependencies

`Desktop/Core` is a dependency-free Swift package for versioned/atomic library
persistence, modern repository parsing, online chapter identities, validated
page paths, spread navigation and shortcut validation.

`Desktop/Midoku` owns native scenes, library/import services, source management,
reader sessions, the AppKit canvas and ImageIO previews. `SourceService` hosts
**AidokuRunner**, pinned to `cc4d06ff399e7169b9c647bccede7cb29bc805c6`, and
`RemotePageCache` preserves source image requests and processing contexts.
ZIPFoundation **0.9.20** and the runner's Wasm3/SwiftSoup/SwiftLint dependencies
are locked in the desktop project's `Package.resolved`. SwiftLint's upstream
package build plugin is enabled; CI skips its interactive trust prompt.
Archive work and previews run through actor services. Display previews are
bounded to 4,000 pixels and cached within 64 MB; originals are kept. Animated
images display their first frame.

The old `Aidoku/` and `Aidoku.xcodeproj` are reference code and are not linked
into the native app. Old Core Data libraries are not automatically migrated.
Built-in Komga/Kavita clients, trackers, dictionaries, iCloud, backup migration,
RAR/CBR and download queues remain outside this native implementation.

## Validation

```sh
swift test --package-path Desktop/Core
xcodebuild -project Midoku.xcodeproj -scheme Midoku \
  -destination 'platform=macOS' -derivedDataPath build/Desktop \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO test
```

The macOS workflow runs both checks; nightly builds create an unsigned app ZIP.
Distribution signing/notarization is not configured. Workflow definitions do
not establish that CI has already passed.

Development in the cloud uses Linux: **21 portable tests passed**; Swift syntax,
project references, property lists and workflow configuration were checked.
The complete dependency graph also resolved successfully using the locked
versions with `--force-resolved-versions`.
Native compilation, linking, WASM execution, website authentication and mouse/
keyboard interaction cannot be validated here. Native tests cover importer
rollback, independent reader state, a fixture Runner's search → manga details
→ chapter → image cache → resumed progress, and custom HTTP headers/image
processing contexts, plus a WASM package smoke test using the fixture from the
pinned runner checkout. These tests are configured but need a macOS run.

Before release, run the command above and verify an actual modern repository:
install/update a source, browse multiple search pages, read a protected chapter,
complete sign-in and retry, restart with a partial and a fully cached chapter,
then uninstall/reinstall the source. Also test simultaneous readers, panning,
zoom, RTL/LTR spread boundaries, continuous scrolling, shortcuts, shelf multi-
selection, resizing and VoiceOver. Website network access requires the chosen
source's repository, API and image hosts to be allowed by the cloud environment.
