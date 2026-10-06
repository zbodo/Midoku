# Midoku

A free and open source manga reading application for iOS, iPadOS, and macOS, based on [Aidoku](https://github.com/Aidoku/Aidoku). Midoku retains Aidoku’s interface and services, with separate library and reader windows on Mac Catalyst.

<p>
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/library-noframe.png" width="25%" alt="Library">
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/source-noframe.png" width="25%" alt="Source">
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/reader-noframe.png" width="25%" alt="Reader">
</p>

## Features

- No ads
- Local file reading (CBZ)
- Built-in reading service providers (Komga, Kavita, Suwayomi)
- WASM external source system
- Downloads
- Tracker integration (AniList, MyAnimeList, etc.)
- OCR dictionary lookup

## Mac Catalyst

The original Aidoku interface is also available as a Mac Catalyst target with a main library window and a separate reusable reader window. Requires macOS 15+. See [Mac build, controls and validation](docs/Mac-Catalyst.md).

## Building Midoku

Open `Midoku.xcodeproj`, select the **Midoku** scheme, and choose an iOS device/simulator or **My Mac (Mac Catalyst)**. Mac Catalyst requires macOS 15 or later. Configure your development team for a signed build.

For an unsigned Mac build:

```sh
xcodebuild -project Midoku.xcodeproj -scheme Midoku -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/Midoku -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

The product is `build/Midoku/Build/Products/Debug-maccatalyst/Midoku.app`, with the default application identifier `app.midoku.Midoku`. See [desktop controls and compatibility](docs/Mac-Catalyst.md).

Midoku’s project and release automation belong to [zbodo/Midoku](https://github.com/zbodo/Midoku). Aidoku’s TestFlight, website and upstream releases distribute Aidoku; they are separate from Midoku.

## Upstream and licensing

Aidoku was created by Skitty and its contributors. Upstream authorship, license notices and file headers are retained. AidokuRunner and the community source ecosystem retain their original names and protocols for compatibility.

The app code is licensed under [GPLv3](LICENSE), excluding translations. Translations are licensed separately under [Apache 2.0](https://spdx.org/licenses/Apache-2.0.html).

Aidoku’s upstream contribution and distribution terms are documented in its [README](https://github.com/Aidoku/Aidoku#contributing) and [CLA](https://gist.github.com/Skittyblock/893952ff23f0df0e5cd02abbaddc2be9). Renaming this fork does not change the upstream licenses or grant an upstream distribution exception.

### Translations

Aidoku’s upstream translations are maintained on [Weblate](https://hosted.weblate.org/engage/aidoku/). Midoku retains those translations and their attribution.
