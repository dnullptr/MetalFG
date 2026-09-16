# MetalFG: Low-Latency Frame Generation & Asynchronous Timewarp (ATW) for iOS 16 (Rootless)

**MetalFG** is a Proof of Concept (PoC) iOS tweak designed for rootless jailbreak environments (Dopamine, Palera1n on iOS 16.x) targeting 120Hz ProMotion devices (iPhone 13 Pro/Max, iPhone 14 Pro/Max, iPhone 15 Pro/Max, and iPad Pro). 

It intercepts the Metal graphics pipeline of native games, samples real-time 200Hz device motion data via `CoreMotion`, computes a 3D perspective homography matrix ($H = K \cdot R^T \cdot K^{-1}$), and synthesizes intermediate reprojected frames between native game frames to double the perceived frame rate from 60 FPS to a fluid 120 FPS with near-zero motion-to-photon latency.

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
                       | - Blits texture to double-buffer     |
                       | - Records timestamp & attitude q0    |
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
                                              | CoreMotion High-Freq Tracker    |
                                              | - Samples attitude q1 @ 200Hz   |
                                              | - Extrapolates to display VSYNC |
                                              | - Δq = q1 * q0^(-1)             |
                                              +----------------+----------------+
                                                               |
                                              +----------------v----------------+
                                              | Camera Homography Generator     |
                                              | H = K * R(Δq)^T * K^(-1)        |
                                              +----------------+----------------+
                                                               |
                                              +----------------v----------------+
                                              | MetalFGWarper Reprojection Pass |
                                              | - Inverse Homography Sampler    |
                                              | - Bilinear Clamping + Edge Fade |
                                              | - Encodes to CAMetalDrawable    |
                                              +----------------+----------------+
                                                               |
                                                               v
                                                [ Synthetic Frame N+0.5 Shown ]
```

---

## Technical Details

### 1. Mathematics of Asynchronous Timewarp (ATW)
When a player tilts, pitches, or turns the device, the camera orientation changes. For purely rotational camera motion (dominant in first-person and third-person mobile games):
- **Intrinsic Camera Matrix ($K$)**: Defined in Normalized Device Coordinates (NDC $[-1, 1]$) with vertical field-of-view $\theta$ and aspect ratio $A$:
  $$f_y = \frac{1}{\tan(\theta / 2)}, \quad f_x = \frac{f_y}{A}, \quad K = \begin{pmatrix} f_x & 0 & 0 \\ 0 & f_y & 0 \\ 0 & 0 & 1 \end{pmatrix}$$
- **Camera Rotational Delta ($R$)**: Computed from the relative quaternion $\Delta q = q_{\text{target}} \cdot q_{\text{base}}^{-1}$ adjusted for display orientation (Portrait, Landscape Left, Landscape Right).
- **Homography Matrix ($H$)**: Maps target frame pixels back to the source frame:
  $$H = K \cdot R^T \cdot K^{-1}$$
- **Fragment Shader Sampling**:
  Given target pixel $\mathbf{x}_t = (x, y, 1)^T$, the source location is:
  $$\mathbf{x}_s \sim H \mathbf{x}_t \implies u = \frac{x_s + 1}{2}, \quad v = \frac{1 - y_s}{2}$$

### 2. Swapchain Starvation Prevention
- Standard game engines configure `CAMetalLayer.maximumDrawableCount = 2` (double buffering). Attempting to acquire an extra drawable (`nextDrawable`) for synthetic frame injection while the game holds a drawable will deadlock the render thread.
- `MetalFG` hooks `CAMetalLayer` to enforce `maximumDrawableCount = 3` (triple buffering), ensuring continuous headroom for synthetic frame submission without stalling the game engine.
- A backpressure guard drops synthetic frames immediately if GPU queue depth reaches $\ge 2$.

### 3. Edge Guard & Vignette
- Extreme device rotations expose regions outside the original camera frustum (disocclusion).
- `Shaders.metal` applies a smooth Hermite interpolation (`smoothstep`) edge-fade to black within the outer 2.5% viewport boundary, preventing pixel streaking along screen edges.

### 4. Zero-Dependency Shader Delivery
- `Shaders.metal` is automatically compiled to `default.metallib` via `xcrun` during package staging.
- `MetalFGWarper.mm` also contains an embedded, runtime-compiled MSL fallback. If App Sandbox restrictions or missing paths prevent loading the `.metallib`, the tweak compiles the shader directly in memory via `[device newLibraryWithSource:options:error:]`.

---

## Project Structure

```
MetalFG/
├── Makefile                     # Theos rootless build configuration
├── control                      # Debian package metadata
├── MetalFG.plist                # Substrate filter (UIKit applications)
├── README.md                    # Documentation
├── Headers/
│   ├── ShaderTypes.h            # Shared vertex, uniform, and buffer structures
│   ├── CoreMotionTracker.h      # High-frequency 200Hz orientation tracking & math
│   ├── MetalFGWarper.h          # Metal pipeline state, texture double-buffer & render encoder
│   └── MetalFGSynchronizer.h    # 120Hz CADisplayLink scheduler & frame pacing
├── Shaders/
│   └── Shaders.metal            # Metal Shading Language ATW vertex & fragment shaders
└── Source/
    ├── CoreMotionTracker.mm     # Sensor fusion, SLERP, and homography implementation
    ├── MetalFGWarper.mm         # Pipeline compilation, GPU blit cache, and draw dispatch
    ├── MetalFGSynchronizer.mm   # CADisplayLink ProMotion synchronizer loop
    └── Tweak.xm                 # Logos hooks for CAMetalLayer, CAMetalDrawable, and MTLCommandBuffer
```

---

## Build & Installation

### Prerequisites
1. **Theos**: Installed and configured with `THEOS_PACKAGE_SCHEME = rootless`.
2. **iOS 16 SDK**: Placed in `$THEOS/sdks/iPhoneOS16.5.sdk` (or latest iOS 16 SDK).
3. **macOS / Linux / iOS host**: Clang with arm64/arm64e support.

### Building the Tweak
Run the following commands in the project root:

```bash
# Clean previous builds
make clean

# Compile and package for iOS 16 Rootless
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

The resulting package will be generated in the `packages/` directory:
```
packages/com.dnullptr.metalfg_1.0.1_iphoneos-arm64.deb
```

---

## Deployment & Testing on Jailbroken Device

### 1. Install via Sileo / Zebra or SSH
Transfer and install the package onto your Dopamine / Palera1n jailbroken device:

```bash
scp -P 2222 packages/com.dnullptr.metalfg_1.0.1_iphoneos-arm64.deb root@<DEVICE_IP>:/var/mobile/
ssh -p 2222 root@<DEVICE_IP>
dpkg -i /var/mobile/com.dnullptr.metalfg_1.0.1_iphoneos-arm64.deb
```

### 2. Verify Operation & Real-Time Logs
Filter tweak logs via `oslog` or `log stream`:

```bash
log stream --level debug --predicate 'sender contains "MetalFG" or eventMessage contains "MetalFG"'
```

Expected log output:
```
[MetalFG] Initializing MetalFG (Asynchronous Timewarp Frame Generation)...
[MetalFG] CoreMotionTracker started at 200.0 Hz.
[MetalFG] MetalFGWarper initialized successfully for pixelFormat 80.
[MetalFG] Synchronizer started on dedicated 120Hz display link thread.
[MetalFG] Performance: Native: 60.1 FPS | Synthetic: 59.9 FPS | Total: 120.0 FPS
```

### 3. Visual Verification (Debug Tint Overlay)
To visually distinguish synthetic frames from native game frames, enable the debug tint overlay:

```bash
defaults write /var/jb/var/mobile/Library/Preferences/com.metalfg.prefs.plist debugTint -bool true
defaults write /var/jb/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist debugTint -bool true
```

*When enabled, synthetic frames will render with a subtle translucent green tint, allowing you to instantly observe the alternating 60 FPS native / 60 FPS synthetic frames at 120Hz.*

### 4. Customizing Field of View (FOV)
If a specific game uses a narrower or wider camera FOV:
```bash
defaults write /var/jb/var/mobile/Library/Preferences/com.metalfg.prefs.plist fovY -float 85.0
defaults write /var/jb/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist fovY -float 85.0
```

