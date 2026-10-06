# Midoku for macOS

The app uses AppKit and SwiftUI directly, requires **Apple Silicon and macOS 14+**, and has separate
library, source browser, manga details, website and reader windows. Open
**Midoku.xcodeproj**, select **Midoku**, and run on **My Mac** in **Xcode 16+**.
Select a development team to run a signed sandboxed build.

Debug and Release builds set `ARCHS = arm64`. CI also passes `ARCHS=arm64`
explicitly so the app, tests and Swift Package dependencies use the same
architecture. The nightly workflow checks the app's arm64 architecture before
packaging it. Intel Macs are not supported.

CI builds and tests use GitHub's `xcode-27` Apple Silicon runner (macOS 27)
with Xcode 27.1 selected via `DEVELOPER_DIR`. This runner image is currently
in public preview; Xcode 27.2 Beta is not selected. Each job prints the actual
macOS, Xcode and Swift versions. Available versions are listed in the
[runner image documentation](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

If Xcode reports `Unable to resolve module dependency` together with
`built for incompatible target`, inspect the target triples in the build log.
Pull the latest project configuration, select **My Mac** on an Apple Silicon
Mac, then use **Product → Clean Build
Folder** before rebuilding. Package resolution succeeding does not verify
that the app and its dependencies were built for matching architectures.

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
- Adaptive paging chooses one, two or more pages from the available viewport
  width/height and image aspect ratios. Each turn shifts the leading page by
  exactly one (1–3 → 2–4); resizing keeps that page. Older single/spread
  preferences migrate to adaptive paging. The single-cover exception is removed.
  Nonempty chapters always show at least one page, including narrow windows and
  landscape images. LTR renders pages in ascending order, RTL in descending
  order; both advance the logical leading page by one. Landscape images
  (width > height) occupy two page slots, but remain one unsplit image and one
  navigation/progress entry. If two slots do not fit, the entire image is fitted
  into the available viewport as the sole page.
- Adaptive paging and continuous reading use
  the same AppKit scrolling viewport. Click the outer 37.5% areas to turn pages;
  the center toggles controls. Sides follow reading direction. Continuous mode
  clicks only toggle controls. Dragging cancels a click and never pans the page.
- Double-click the actual image to open a separate image-preview sheet; its
  zoom controls do not alter the reading position. Right-click offers preview,
  navigation and fit actions. Failed pages can be clicked to retry.
- The wheel turns fitted pages. On tall/zoomed pages it scrolls within the page;
  reaching an edge needs a new gesture to turn. Trackpad momentum cannot turn
  additional pages. Continuous mode always scrolls. Command-wheel and pinch
  zoom the main viewport; optional reverse wheel paging only affects fitted pages.
- The eHunter-style defaults bind A / Left / Up to previous page and D / Right /
  Down to next page. Space / Shift-Space (also Page Down / Page Up) scroll
  90% of a viewport in continuous mode and turn pages in paged mode. Q toggles
  controls, T thumbnails, F a thumbnail overview, R reading settings, and [ / ]
  adjust fit-width by five percentage points. Control-Command-F is native full screen.
- Settings → Keyboard supports multiple aliases, removal/unbinding, conflicts
  and restoring defaults. Existing customized bindings migrate and take priority
  over new defaults. Optional directional left/right arrows only affect keys
  assigned to page navigation. Escape closes panels or reveals controls; text
  input, native controls and sheets retain their own keyboard handling.
- Page index and relative page offset are saved, including long-image positions.
  Continuous pages load near the viewport and release distant decoded images.
  Changing window size, controls or zoom preserves the current page anchor.
- The first reader shows a dismissible controls popover; the question-mark
  toolbar button opens it again. Reading Settings includes click paging, side
  swapping, wheel reversal and directional-arrow options.

## Architecture and dependencies

`Desktop/Core` is a dependency-free Swift package for versioned/atomic library
persistence, modern repository parsing, online chapter identities, validated
page paths, adaptive page selection and single-step navigation, click/drag/wheel input policies and versioned
multi-binding shortcut validation.

`Desktop/Midoku` owns native scenes, library/import services, source management,
reader sessions, the AppKit viewport and ImageIO previews. `SourceService` hosts
**AidokuRunner**, pinned to `cc4d06ff399e7169b9c647bccede7cb29bc805c6`, and
`RemotePageCache` preserves source image requests and processing contexts.
ZIPFoundation **0.9.20** and the runner's Wasm3/SwiftSoup/SwiftLint dependencies
are locked in the desktop project's `Package.resolved`. SwiftLint's upstream
package build plugin is enabled; CI skips its interactive trust prompt.
Archive work and previews run through actor services. Display previews are
bounded to 4,000 pixels (8,192 in the separate detail preview) and cached
within 64 MB; originals are kept. This preview is not a full-resolution tiled
image viewer. Animated
images display their first frame.

The old `Aidoku/` and `Aidoku.xcodeproj` are reference code and are not linked
into the native app. Old Core Data libraries are not automatically migrated.
Built-in Komga/Kavita clients, trackers, dictionaries, iCloud, backup migration,
RAR/CBR and download queues remain outside this native implementation.

## Validation

```sh
swift test --package-path Desktop/Core
xcodebuild -project Midoku.xcodeproj -scheme Midoku \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Desktop \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

The macOS workflow runs both checks; nightly builds create a Developer ID signed
app DMG using repository secrets, uploaded directly without a ZIP wrapper.
See [CI signing setup](CI_SIGNING.md).
Notarization is not configured. Workflow definitions do not establish that CI
has already passed.

Development in the cloud uses Linux: **33 portable tests passed**; Swift syntax,
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
then uninstall/reinstall the source. The previous baseline was reported to
compile and launch on the user's Mac; this reader refactor still requires a
macOS build and interactive checks. Verify simultaneous readers, RTL/LTR click
zones, drag cancellation, double-click without a stray turn, tall-page boundary
scrolling, trackpad inertia, adaptive one/two/multi-page resizing, one-page turns
near the chapter end, continuous position restoration, shortcut migration,
text-field focus, resizing and VoiceOver. Website network access requires the chosen
source's repository, API and image hosts to be allowed by the cloud environment.
