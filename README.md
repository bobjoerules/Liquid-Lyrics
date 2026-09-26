# Liquid Player

Liquid Player is a synchronized lyrics and music player companion for iOS, powered by the **Spotify Web API** and the **[Spicy Lyrics API](https://developers.spicylyrics.org/docs)**. Built using **SwiftUI**, Liquid Player connects to Spotify to track real-time playback and render live, syllable-synced bouncing lyrics with smooth physics animations.

---

## Key Features

### High-Fidelity Lyrics Rendering
- **Syllable-Level Timing**: Word-by-word and syllable-by-syllable synchronized karaoke highlighting.
- **Background Vocal Synchronization**: Real-time syllable sync for parenthetical background vocals alongside lead vocals.
- **Multi-Line Simultaneous Playback**: Simultaneous active highlighting for overlapping duet lines, vocal sustains, and concurrent harmonies.
- **Duet-Aware Layout**: Identifies primary and guest/background vocalists, rendering lead vocals on the left and duet partners opposite-aligned on the right.
- **Romanization & Translation**: Supports transliterations and translations directly from the Spicy Lyrics API.
- **Physics-Driven Motion**: Damped harmonic oscillator springs for fluid word bounces, interlude indicators, and seamless auto-scrolling.

### Live Spotify Integration
- **Live Playback Sync**: Connects to the Spotify Web API to sync currently playing song, artist, album art, progress, and duration.
- **Full Remote Controls**: Play, Pause, Next, Previous, Seek slider, and Shuffle directly from Liquid Player.
- **Micro-Interpolation**: High-resolution timer interpolates playback progress between Spotify poll events for 60/120fps ultra-fluid lyric animations.

### iOS
- **Spacebar Playback Control**: Toggle play/pause globally using the Spacebar keyboard shortcut.
- **Liquid Glass Styling**: Uses Apple's native `.glassEffect(in:)` for Liquid Glass styling (iOS 26.0+) with high-fidelity glassmorphic fallbacks on earlier versions.
- **Custom Icon**: Uses a custom **`LiquidPlayer.icon`** asset bundle (managed under `ios/LiquidPlayeriOS/Resources/`).

---

## Local Development & Setup

This repository does not track `.xcodeproj` or `.xcworkspace` files in git (they are ignored via [.gitignore](.gitignore)). Instead, the Xcode project is declaratively defined in [ios/project.yml](ios/project.yml) and generated on demand using **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**.

### Prerequisites

- macOS with Xcode installed
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (installable via Homebrew):
  ```bash
  brew install xcodegen
  ```

### Generating the Xcode Project

To generate or update the Xcode project locally:

```bash
cd ios
xcodegen generate
```

This generates `LiquidPlayeriOS.xcodeproj` directly in the `ios/` folder. You can then open it with Xcode:

```bash
open LiquidPlayeriOS.xcodeproj
```

---

## Manual Builds

GitHub Actions includes a manual workflow at [.github/workflows/build-mobile.yml](.github/workflows/build-mobile.yml).

- `ios_export`: export an unsigned device `ipa` for sideload tools or an unsigned `simulator-app`

The workflow generates the Xcode project from [ios/project.yml](ios/project.yml) using XcodeGen on the macOS runner, then builds either:

- an unsigned device `.ipa` suitable for local resigning/sideloading tools such as Sideloadly
- an unsigned iOS Simulator `.app` zip

## License

This project is licensed under the **AGPL-3.0 License**, inherited from the [Spicy Lyrics](https://github.com/Spikerko/spicy-lyrics) project. See the [LICENSE](LICENSE) file for the full text.

---

*Made by [Bobjoerules](https://bobjoerules.com) with the help of Antigravity's available models. Based on [Spicy Lyrics](https://github.com/Spikerko/spicy-lyrics) - A [Spicetify](https://spicetify.app/) Extension*
