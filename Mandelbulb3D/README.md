# Mandelbulb 3D

A real-time 3D fractal renderer for macOS (Apple Silicon), built with
Xcode, Objective-C++/C++, and Metal. Every fractal is ray-marched on the
GPU per-frame — there's no precomputed mesh or voxel grid — so you can
fly around and switch formulas live.

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

| Input                    | Effect                             |
|---------------------------|-------------------------------------|
| Click + drag               | Orbit the camera                   |
| Scroll / trackpad pinch    | Zoom in/out                        |
| `1`–`6`                     | Jump directly to a fractal type    |
| `Tab` / `⇧Tab`              | Cycle to next / previous fractal   |
| `J`                          | Toggle Julia mode (Mandelbulb only) |
| `+` / `-`                     | Increase/decrease fractal power   |
| `[` / `]`                     | Decrease/increase iteration detail |
| `Space`                        | Toggle power animation            |
| `S`                              | Toggle soft shadows              |
| `R`                                | Reset camera + parameters to the current fractal's preset |

The window title always shows which fractal is active.

## The fractal library

Switching fractal type (`1`–`6` or `Tab`) re-applies that formula's own
default parameters, iteration count, epsilon, and camera framing — they
don't share settings, since a Mandelbox and a Menger Sponge want very
different ray-march tuning. All six live in `Shaders.metal`; each is a
standard, widely-published formula:

1. **Mandelbulb** (`mandelbulbDE`) — Daniel White & Paul Nylander's 2009
   spherical ("triplex") power-`n` formula, the one that gave the whole
   fractal family its name and that Mandelbulb 3D, Fragmentarium, and
   countless Shadertoy pieces are built on. Convert to spherical
   coordinates `(r, θ, φ)`, raise `r` to the `power` and multiply `θ`/`φ`
   by it, convert back, add the original point. The running derivative
   `dr` turns the escape-time count into a distance bound. Press `J` to
   flip it into **Juliabulb** mode — same formula, but the added
   constant is a fixed point (`juliaC`) instead of the ray-march sample
   position, which is the standard Mandelbrot-vs-Julia distinction
   carried into 3D.
2. **Mandelbox** (`mandelboxDE`) — Tom Lowe's "Amazing Box", the DE
   popularized by Rrrola/Tglad on Fractal Forums. Each iteration:
   box-fold every axis into `[-1, 1]`, ball-fold around the origin
   (points inside a shrinking sphere get inverted outward), then scale
   and re-add the original point. Produces the sharp-edged, nested-cube
   look distinct from the Mandelbulb's organic blobbiness.
3. **Menger Sponge** (`mengerSpongeDE`) — Inigo Quilez's folded-box SDF
   (see iquilezles.org/articles/menger). Repeatedly folds space into a
   unit cell and subtracts a "cross" of three boxes from a running box
   SDF at ever-finer scale — an exact, closed-form distance estimator
   for the classic Menger sponge (no IFS point-cloud approximation
   needed).
4. **Sierpinski Tetrahedron** (`sierpinskiDE`) — the standard
   tetrahedral-fold IFS distance estimator catalogued across the
   Fractal Forums wiki and Syntopia's "Distance Estimated 3D Fractals"
   series: reflect into the dominant octant pair each step, then scale
   away from a fixed offset.
5. **Quaternion Julia** (`quaternionJuliaDE`) — Keenan Crane's "Ray
   Tracing Quaternion Julia Sets on the GPU" (GPU Gems). Iterates
   `q ← q² + c` in the quaternions (4D), tracking a derivative
   quaternion for the distance bound, and renders the `w = 0` slice of
   the 4D set through 3D space.
6. **Apollonian Gasket** (`apollonianDE`) — Knighty's sphere-inversion
   fractal (Fractal Forums / iquilezles.org): repeatedly fold into the
   unit cell and invert through a sphere, accumulating total scale to
   correct the distance estimate back to world space.

## How it works

- **`Camera.h`** — a small, dependency-free C++ orbit camera (azimuth /
  elevation / distance around a target).
- **`ShaderTypes.h`** — the `Uniforms` struct shared between the host
  app and the GPU shader, plus the `FractalType` enum selecting which
  formula `sceneDE()` evaluates. Every vector field is `float4` rather
  than `float3`; this sidesteps a classic Metal pitfall where
  `simd_float3` is 16 bytes on the CPU but MSL only guarantees 16-byte
  *alignment* (not size) for `float3`, which can silently desync the
  two sides' struct layout.
- **`Shaders.metal`** — the fractal library described above, plus the
  shared ray marcher, normal estimation (central-difference gradient of
  the distance field), ambient occlusion and soft shadows (both cheap
  extra distance-field marches), and orbit-trap-based surface coloring.
  `sceneDE()` dispatches to whichever formula is selected.
- **`Renderer.mm`** — owns the Metal device/pipeline, holds the
  per-fractal parameter presets (`-applyPresetForFractalType:`), builds
  the `Uniforms` each frame, and exposes the input-handling methods that
  `ViewController.mm`'s `MetalView` calls into.
- **`ViewController.mm` / `AppDelegate.mm`** — plain AppKit, built
  entirely in code (no storyboard/xib) so there's nothing to open in
  Interface Builder.

## Performance tuning

The defaults run comfortably at 60fps at window size on M2-class GPUs.
Mandelbox and Sierpinski use higher iteration counts (14) since their
folding formulas are cheap per-iteration; Menger Sponge is capped at 8
folds in the shader regardless of the iteration setting, since its
scale factor compounds geometrically and blows through float precision
well before then. If you push iteration counts or `maxSteps` higher and
want more headroom:

- lower `maxSteps` (`Renderer.mm`, shared across all fractal types)
- raise `epsilon` slightly per-preset (coarser surface hit test,
  cheaper but a bit blobbier)
- trim the AO loop in `ambientOcclusion` (currently 5 samples) in
  `Shaders.metal`
