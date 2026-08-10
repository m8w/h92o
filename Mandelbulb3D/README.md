# Mandelbulb 3D

A real-time Mandelbulb fractal renderer for macOS (Apple Silicon), built
with Xcode, Objective-C++/C++, and Metal. The entire fractal is
ray-marched on the GPU per-frame — there's no precomputed mesh or voxel
grid — so you can fly around and tweak the fractal's parameters live.

## Requirements

- Xcode 15 or newer
- macOS 13 (Ventura) or newer, on an Apple Silicon Mac (developed/tuned
  for the Mac mini M2 Pro's GPU, but runs on any Metal-capable Mac)

## Build & run

```sh
open Mandelbulb3D.xcodeproj
```

Select the `Mandelbulb3D` scheme and press **Run** (⌘R). No signing
setup is required for a local run — Xcode's "Sign to Run Locally" is
sufficient.

## Controls

| Input                | Effect                          |
|-----------------------|----------------------------------|
| Click + drag           | Orbit the camera                |
| Scroll / trackpad pinch | Zoom in/out                     |
| `+` / `-`               | Increase/decrease fractal power |
| `[` / `]`               | Decrease/increase iteration detail |
| `Space`                 | Toggle power animation           |
| `S`                      | Toggle soft shadows              |
| `R`                      | Reset camera and power           |

## How it works

- **`Camera.h`** — a small, dependency-free C++ orbit camera (azimuth /
  elevation / distance around a target).
- **`ShaderTypes.h`** — the `Uniforms` struct shared between the host
  app and the GPU shader. Every vector field is `float4` rather than
  `float3`; this sidesteps a classic Metal pitfall where `simd_float3`
  is 16 bytes on the CPU but MSL only guarantees 16-byte *alignment*
  (not size) for `float3`, which can silently desync the two sides'
  struct layout.
- **`Shaders.metal`** — the actual fractal. `vertexShader` emits a
  full-screen triangle; `fragmentShader` ray-marches each pixel against
  `mandelbulbDE`, the classic power-8 Mandelbulb distance estimator
  (Daniel White / Paul Nylander's 2009 formula, as used across
  Mandelbulb 3D, Fragmentarium, and Shadertoy):
  - iterate `z` in spherical ("triplex") form: `r, theta, phi`, raised
    to `power` each step, plus the original point `c`
  - track the running derivative `dr` to convert the escape-time
    iteration into a signed distance bound
  - an orbit trap (`min` distance to the origin seen during iteration)
    drives the surface coloring
  - normals come from a central-difference gradient of the distance
    field; ambient occlusion and soft shadows are both cheap
    distance-field marches of their own
- **`Renderer.mm`** — owns the Metal device/pipeline, builds the
  `Uniforms` each frame, and exposes the input-handling methods that
  `ViewController.mm`'s `MetalView` calls into.
- **`ViewController.mm` / `AppDelegate.mm`** — plain AppKit, built
  entirely in code (no storyboard/xib) so there's nothing to open in
  Interface Builder.

## Performance tuning

The defaults (`maxIterations = 10`, `maxSteps = 256`, `epsilon =
0.0008`) run comfortably at 60fps at window size on M2-class GPUs.
If you push `power` or iteration count higher and want more headroom:

- lower `maxSteps` in `Renderer.mm`'s `initWithMetalKitView:` (fewer
  ray-march steps per pixel)
- raise `epsilon` slightly (coarser surface hit test, cheaper but a bit
  blobbier)
- lower `aoStrength`'s cost indirectly by trimming the AO loop in
  `ambientOcclusion` (currently 5 samples) in `Shaders.metal`
