<div align="center">

<img src="metalFG_logo.png" alt="MetalFG Logo" width="240" />

# ⚡ MetalFG

### Real-Time GPU Frame Generation & Optical Flow Interpolation for ProMotion iOS Devices

[![iOS](https://img.shields.io/badge/iOS-16.0%2B%20(15.x%20Untested)-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/dnullptr/MetalFG)
[![Jailbreak](https://img.shields.io/badge/Jailbreak-Rootless%20(Dopamine%20%2F%20Palera1n)-34C759?style=for-the-badge)](https://github.com/dnullptr/MetalFG)
[![Architecture](https://img.shields.io/badge/Arch-arm64%20%7C%20arm64e-FF9500?style=for-the-badge)](https://github.com/dnullptr/MetalFG)
[![Display](https://img.shields.io/badge/ProMotion-60%20%E2%86%92%20120%20FPS-AF52DE?style=for-the-badge)](https://github.com/dnullptr/MetalFG)
[![Status](https://img.shields.io/badge/Status-Stable%20v3.0.0-30D158?style=for-the-badge)](https://github.com/dnullptr/MetalFG/releases/latest)

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy%20Me%20a%20Beer-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/dnullptr)
[![PayPal](https://img.shields.io/badge/PayPal-Donate-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/dnullptr)

</div>

---

## 📖 Overview

**MetalFG** is a free, open-source, driver-level **GPU Frame Generation & Optical Flow Interpolation tweak** for rootless jailbreak environments (**Dopamine**, **Palera1n**) on 120Hz ProMotion devices (tested on iPhone 13 Pro Max on iOS 16; iPhone 14 Pro / Pro Max, iPad Pro, and iOS 15 ProMotion testers are very welcome!).

Inspired by PC frame generators like **Lossless Scaling (LSFG)**, **DLSS 3**, and **[MFG-SUPER-MOTION (SMFG)](https://github.com/NODIX-TECH/MFG-SUPER-MOTION)**, MetalFG intercepts 60 FPS (or 30 FPS) Metal games—such as *Genshin Impact*—and synthesizes true midpoint optical-flow frames directly on the Apple Silicon GPU to drive your 120Hz ProMotion display at a silky-smooth **120 FPS**.

> [!NOTE]
> **Stable Status:** **v3.0.0** is the first **stable** release of MetalFG. Every generated frame *and* every real game frame now reaches the screen in the correct order, each held for a true `8.33ms` 120Hz refresh. Edge cases across other games and engines are still being refined—feedback is very welcome!

---

## 🚀 What's New in v3.0.0 (and Why It's a Major Version)

Versions `1.x`–`2.x` were all about **what** frame to generate (extrapolation → true midpoint interpolation → SMFG optical flow). `v2.3.0` finally fixed **which order** frames were shown in, but 120 FPS still never felt like *real* 120 FPS. On-device pacing measurements (`presentedTime`) revealed why:

- Every game frame needs **two** presented images (`S_{N-0.5}` + `Frame N`), plus one on screen and one the game is rendering = **4 drawables**—but a `CAMetalLayer` swapchain only has **3**.
- So up to **25–40% of the real game frames were silently skipped**, and the screen kept alternating `S, S, N, S, S…` instead of `S, N, S, N…`. Presets and sliders couldn't help, because the bottleneck was the presentation pipeline, not image quality.

`v3.0.0` replaces the whole presentation architecture, which is why it's a **major** version:

1. **MetalFG-Owned Output Swapchain:** MetalFG now renders into its **own `CAMetalLayer`**, attached directly on top of the game's layer. The game's swapchain is only *read*—never starved—so the 1-second `nextDrawable` hangs and frame skipping are gone.
2. **Back-to-Back `S → N` Presentation:** Both frames are presented from a dedicated serial queue right after interpolation (no more display-link polling that skipped `N` while the GPU was busy). `afterMinimumDuration` keeps each one on screen for exactly one 120Hz refresh.
3. **Frame-Serial Ordering Guard:** A stale `Frame N` can never be shown after a newer synthetic frame, and if the game ever gets a frame ahead, that frame's `N` is skipped instead of building up latency.
4. **Live Pacing Diagnostics:** The HUD now measures what the display *actually* showed (see the HUD section below).

Your saved tuning sliders and presets carry over unchanged.

---

## 🎁 Why MetalFG is 100% Free & Open-Source Forever

**I will NEVER charge money for MetalFG.**

I spent a month of sleepless nights researching optical flow, debugging Metal swapchains, fighting ghosting and judder, and surviving Dopamine userspace-reboot bootloops on my personal iPhone 13 Pro Max to build a tweak that I would have happily paid for myself. It completely changed the way I enjoy my phone—making me happier with my 13 Pro Max than if I had just upgraded to a newer device.

Rather than wrapping this in DRM only to find it "cracked" on a Telegram group, I believe in giving this gem to the jailbreak community as a genuine **gift**.

### 🍺 Support, Contributions & Buying Me a Beer!

I study overtime, so my free time is super limited. Because MetalFG is **100% open-source**, community help is a huge opportunity:
- **Contributions, Ideas & Tips:** Have ideas to optimize the Metal compute shaders, refine optical flow, or add per-game profiles? PRs, issues, and tips are more than welcome!
- **Testers Wanted (including iOS 15!):** I haven't personally tested iOS 15 ProMotion devices yet—if you're on iOS 15 or testing different Metal games, I look forward to your feedback!
- **Donations:** If MetalFG breathes new life into your device the way it did for mine, and you'd like to buy me a beer (or half a beer! 🍺) for the month of research and debugging, I would be super grateful:

<div align="center">

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20dnullptr-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/dnullptr)
[![PayPal](https://img.shields.io/badge/PayPal-paypal.me%2Fdnullptr-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/dnullptr)

</div>

---

## 🧠 Architecture (True 1-Frame Latency Midpoint Engine)

Unlike early frame extrapolators (`v1.0`) that tried to guess future frames and caused rubberbanding, **MetalFG** uses a **Full 1-Frame Latency True Midpoint Interpolation Pipeline** (`S_{N-0.5}` between `Frame N-1` and `Frame N`), presented through its **own output swapchain** with hardware-paced 120Hz `CARenderServer` VSYNC scheduling:

```
                                 [ Game Engine Render Loop ]
                                              |
                            (finishes rendering Native Frame N)
                                              |
                            [MTLCommandBuffer presentDrawable:]
                                              |
                       +----------------------v-----------------------+
                       |      MetalFG Command Buffer Interceptor      |
                       | - Suppresses the game's own present          |
                       | - Queues Frame N on a serial present queue   |
                       +----------------------+-----------------------+
                                              |
                       +----------------------v-----------------------+
                       |    Pass 1-3: Midpoint Synthesis S_{N-0.5}    |
                       | - Coarse-to-Fine Optical Flow (80x45)        |
                       | - 5x5 Bilateral Fluid & Outlier Filter       |
                       | - Sub-Block Silhouette Edge Resolver         |
                       | - Clamped Catmull-Rom 5-Tap Sharp Read       |
                       +----------------------+-----------------------+
                                              |
                 +----------------------------+----------------------------+
                 |                                                         |
                 v                                                         v
   [ Synthetic Midpoint S_{N-0.5} ]                      [ Ground Truth Frame N ]
    (presented 1st, held 8.33ms)                      (presented 2nd, held 8.33ms)
                 |                                                         |
                 +----------------------------+----------------------------+
                                              |
                       +----------------------v-----------------------+
                       |    MetalFG-Owned Output CAMetalLayer (v3)    |
                       | - Own 3-drawable swapchain on top of game    |
                       | - Game swapchain is only read, never starved |
                       | - afterMinimumDuration 120Hz VSYNC pacing    |
                       +----------------------------------------------+
```

### Key Technical Highlights
1. **True Midpoint Bidirectional Interpolation (`Shaders/Shaders.metal`):**
   - Warps `Frame N` backward (`uv + effMV * t`) and `Frame N-1` forward (`uv - effMV * t`) to meet at the exact temporal midpoint ($t = 0.50$), ensuring every moving object advances in monotonic half-steps across every `8.33ms` 120Hz refresh cycle.
2. **SMFG 1.1 Coarse-to-Fine Optical Flow & Parabolic Sub-Pixel Fit:**
   - Evaluates a $3\times3$ RGB+Luminance patch across a 4-ring multi-radius seed search, followed by a **3-level hierarchical coarse-to-fine refinement** (`0.0040 -> 0.0020 -> 0.0009`) and **1D parabolic sub-pixel refinement** (`SubpelMain`).
3. **5x5 Bilateral Fluid Filter & Flat-Region Fill (`FillMain` + `EdgeMain`):**
   - Rejects isolated block outliers (`alone_near`) and propagates high-confidence motion from textured edges into flat/cel-shaded surfaces (e.g., anime skin, sky, indoor walls) while preserving sharp foreground/background boundaries.
4. **Sub-Block Edge Resolver & Foreground Silhouette Occlusion Guard (`Round 53`):**
   - Eliminates ghost halos around player heads and characters by testing the 4 surrounding macroblock vectors per pixel at motion boundaries and switching cleanly to the unoccluded frame when background motion crosses a slower foreground silhouette.
5. **Clamped Catmull-Rom 5-Tap Sharp Reconstruction & Static HUD Protection (`Round 56` + `MarkMain`):**
   - Restores sub-pixel texture crispness lost to bilinear filtering (without ringing) and locks static UI, text, damage numbers, minimaps, and skill icons in place.
6. **100% Dopamine Userspace-Reboot Safe (`Source/Tweak.xm`):**
   - Strictly whitelists third-party application bundles under `/var/containers/Bundle/Application/` before initializing any hooks—never injects into `SpringBoard`, `backboardd`, or system daemons.
7. **MetalFG-Owned Output Swapchain (`Source/MetalFGSynchronizer.mm`, v3.0.0):**
   - Presents `S_{N-0.5}` and `Frame N` into a dedicated `CAMetalLayer` sublayer, so the game's 3-drawable swapchain is never starved and no real frame is ever dropped. Turning FG off removes the layer instantly and the game presents natively again.

---

## 🎛️ In-Game Floating HUD & Live Tuning Panel

MetalFG includes a draggable, touch-passthrough floating pill and frosted-glass tuning menu:
- **Live FPS Meter:** Shows real-time total, native, and synthetic FPS (`⚡ FG: 120 (60+60)`).
- **Live Pacing Line:** `S x✓ y✗ │ N x✓ y✗ │ drop n │ ord n` — measured from what the display *actually* showed each second. `✓` = held for one 120Hz refresh (~8.3ms), `✗` = held shorter/longer, `drop` = never shown, `ord` = two frames of the same kind back-to-back. Turns **green** when pacing is clean (ideal: `S 60✓ │ N 60✓ │ drop 0 │ ord 0`).
- **Single Tap Pill:** Toggle Frame Generation **ON / OFF** instantly with haptic feedback.
- **Double Tap Pill:** Minimize into a compact `36x36` dot.
- **Tap `⚙️` (or Long-Press):** Open the **Live Tuning Panel**:
  - **Presets:** `Clear` (tightest ghost rejection), `Balanced` (true 50% midpoint default), `Fluid` (widest bilateral motion blend).
  - **Sliders:** Live adjustment for *Motion Warp Scale*, *Ghost Rejection*, and *UI / HUD Protection*.

---

## 📦 Installation & Building

### Pre-Built Rootless `.deb`
Download the latest **stable** rootless `.deb` from [**GitHub Releases (Latest)**](https://github.com/dnullptr/MetalFG/releases/latest) and install via **Sileo**, **Zebra**, or **Filza**. Bleeding-edge builds of every `main` commit are published as [**Nightly**](https://github.com/dnullptr/MetalFG/releases/tag/nightly).

### Building from Source (Theos)
```bash
make clean
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```
Generated package: `packages/com.dnullptr.metalfg_<version>_iphoneos-arm64.deb`
