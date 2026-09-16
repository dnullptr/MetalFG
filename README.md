# MetalFG: Real-Time GPU Motion-Interpolated Frame Generation for iOS 16 (Rootless)

**MetalFG** is a high-performance iOS tweak for rootless jailbreak environments (Dopamine, Palera1n on iOS 16.x) targeting 120Hz ProMotion devices (iPhone 13 Pro/Max, iPhone 14 Pro/Max, iPhone 15 Pro/Max, and iPad Pro).

It intercepts the Metal graphics pipeline of 60 FPS capped 3D games (such as Genshin Impact) and synthesizes fluid intermediate frames using a dual-engine motion interpolation pipeline:
1. **GPU Block Motion Estimation (BME) Compute Shader:** Screen-space optical flow running directly on Apple Silicon GPU.
2. **Static UI Masking:** Automatically classifies stationary HUD elements (minimap, health bars, attack buttons, dialogue) to prevent text smearing or distortion.
3. **Touch-Driven Camera Velocity Prior:** Samples finger drag speed on the touchscreen to provide instant camera rotational velocity with zero input lag.

---

## Architecture Overview

```
                                 [ Game Engine Loop ]
                                          |
                              (renders native frame N)
                                          |
                        [MTLCommandBuffer presentDrawable:]
                                          |
                       +------------------v-------------------+
                       |        MetalFG Tweak Hook            |
                       | - Intercepts CAMetalDrawable         |
                       | - Double-buffers native frames       |
                       | - Samples touch swipe velocity       |
                       +------------------+-------------------+
                                          |
                     +--------------------+--------------------+
                     |                                         |
          (VSYNC Tick 2k: 0.0ms)                    (VSYNC Tick 2k+1: +8.33ms)
                     |                                         |
                     v                                         v
        [ Native Frame N Shown ]                 [ MetalFGSynchronizer Tick ]
                                                               |
                                              +----------------v----------------+
                                              | Touch Camera Velocity Prior     |
                                              | - Measures swipe velocity Δu,Δv |
                                              +----------------+----------------+
                                                               |
                                              +----------------v----------------+
                                              | GPU Block Motion Estimation     |
                                              | - 80x45 macroblock grid         |
                                              | - Compares Frame N-1 and N      |
                                              | - Static UI detection & lock    |
                                              +----------------+----------------+
                                                               |
                                              +----------------v----------------+
                                              | MetalFGWarper Motion Pass       |
                                              | - Forward motion extrapolation  |
                                              | - Preserves UI text sharpness   |
                                              | - Encodes to CAMetalDrawable    |
                                              +----------------+----------------+
                                                               |
                                                               v
                                                [ Synthetic Frame N+0.5 Shown ]
```

---

## Technical Details

### 1. GPU Block Motion Estimation (BME)
- Analyzes consecutive native frames on an $80\times45$ macroblock grid on the GPU.
- Each block evaluates pixel luminance deltas across a localized search window centered on the touch velocity prior.
- Generates a normalized 2D motion vector field texture (`RG16Float`).

### 2. Static UI Masking
- Traditional frame generation often smears text, health bars, and minimaps.
- MetalFG evaluates difference metrics across block centers: if pixel differences between frames are below threshold $\epsilon$, the block is tagged as **Static UI**.
- UI pixels receive a $(0, 0)$ displacement vector, guaranteeing that on-screen text, menus, and controls remain 100% sharp and unwarped.

### 3. Touch-Driven Camera Velocity Prior
- In mobile 3D action games, the vast majority of screen movement comes from thumb swipes rotating the camera.
- `MetalFGTouchTracker` intercepts touch movement events via `UIWindow sendEvent:` to calculate smooth camera angular velocity.
- This gives the GPU search kernel an immediate, accurate motion prior with zero latency penalty.

### 4. Triple Buffering & Backpressure Guard
- Automatically configures `CAMetalLayer.maximumDrawableCount = 3` to prevent swapchain starvation.
- Drops synthetic frames immediately if GPU queue depth reaches $\ge 2$, prioritizing the native game engine.

---

## Floating Status HUD

MetalFG includes a non-intrusive on-screen floating pill HUD:
- **Real FPS Monitoring:** Displays true native FPS and generated synthetic FPS in real time (e.g. `⚡ FG: 120 (60+60)`).
- **Single Tap:** Instantly toggles Frame Generation **ON / OFF** with tactile haptic feedback (`⏸ FG: OFF (Native: 60)`).
- **Double Tap:** Minimizes badge into a compact 36x36 floating dot.
- **Drag:** Freely reposition anywhere on screen.

---

## Build & Installation

### Building the Tweak (Theos)
```bash
make clean
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

Generated package: `packages/com.dnullptr.metalfg_1.0.8_iphoneos-arm64.deb`.
