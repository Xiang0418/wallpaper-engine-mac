# Scene playback integration checks

Run on macOS with Xcode installed:

```sh
bash tests/run-scene-playback.sh '/path/to/3799672625'
```

The test compiles the production scene loader and parsers with minimal application
settings stubs. It needs the local wallpaper fixture (not included in the repository)
and access to macOS media services. Playback stays muted. The volume check happens
while playback is paused.

Checks include real TEX/MP4 extraction, first decoded frame, independent music,
video looping without restarting music, pause/resume, volume, sleep/wake,
missing-scene errors, a failed main background with a successfully decoded small
overlay, and repeated load/stop cleanup.

Phase-one behavior:

- The largest visible image by declared size is treated as the main background.
  This matches fixture 3799672625; scenes without declared sizes or with larger
  decorative layers may need explicit background selection in a later phase.
- Video and MP3 each follow their own timeline. Video audio and scene audio are
  mixed and both follow global volume/mute. This fixture contains a 9.8-second
  video with an audio track and approximately 276 seconds of MP3 audio.
- Preview remains above overlays until the main video produces a decoded frame.
- Extracted media uses a unique temporary directory owned by the scene instance,
  removed on replacement, view teardown, or deinitialization.
- Scene scripts, sound playlists/random playback, effects, and custom property
  evaluation are outside phase one. Stored values are used where supported.

These automated checks do not establish pixel-perfect presentation, perceptually
seamless video boundaries, or long-duration memory stability. Those need desktop
visual/audio checks and a longer profiling session.

## Phase-two rendering

```sh
bash tests/run-scene-rendering.sh '/path/to/3799672625'
```

Requires access to the macOS GPU/window server. A restricted process can fail in
SpriteKit's renderer initialization before reaching application shaders. This
suite compiles production sources, decodes all seven static TEX assets, checks
LZ4/BC3 and truncated inputs, direct project-default bindings, all 30 parent links,
parent scaling, hidden dock children, both packaged fonts and the cover mask's
rendered alpha pixels. Shader compiler errors make the command fail. It writes
`/tmp/we-phase2-scene.png` and `/tmp/we-phase2-dock.png`; these use the low-resolution
preview as a repeatable background. The second image forces the normally hidden
dock visible for QA only. Tests never modify the installed wallpaper package.

Implemented scope:

- TEXB versions 1–4, raw LZ4 blocks, RGBA8888, R8, RG88, BC1/DXT1,
  BC2/DXT3, BC3/DXT5 and encoded JPEG/PNG. Allocated dimensions are distinct
  from content dimensions; padding is cropped. Payload lengths are bounded.
- Every object has a transform container, including anchors and hidden layers.
  Position, Z rotation, XY scale and inherited visibility preserve the parent
  tree. Missing/cyclic links are diagnosed and attached safely at the root.
  Repeated model references remain distinct objects. Draw order follows the
  object list independently of parent depth. Orthographic canvas size and zoom
  are applied; exported editor camera navigation is not a runtime translation.
- In-memory Core Text fonts, stored text, color, alpha and text alignment.
  The integrated phase-three runtime now updates attributed text without replacing its packaged font.
- Built-in solid layers and instance textures; four additive flares; red-channel
  opacity masks; ordered opacity/spin/custom-texture passes; the fixture's round
  frame shader configuration. The integrated spectrum shader consumes actual music frequency data. Spin uses SpriteKit scene time and pauses
  with the scene. Unknown effects are reported through `renderingWarnings`.
- Project defaults resolve direct scalar/color bindings. Missing bindings and
  unsupported expressions retain stored values. The runtime resolves direct script-property bindings; full editable settings remain phase four.
- Font/texture caches belong to the renderer and are cleared on stop/replacement.

Limits requiring further work or external validation:

- This is a port of the tested fixture's effects, not a general shader engine.
  Other frame combinations, perspective/3D cameras, text wrapping/spacing and
  animated texture sequences are not covered. Text baselines and blend appearance
  still need comparison with the original Windows renderer.
- The missing `particle/beam/beam_1` engine texture has a procedural approximation;
  the original resource is not bundled. The integrated runtime simulates the fixture rope trail.
- Windows reference screenshots and original engine resources were not available,
  so these tests do not establish pixel-identical parity or complete support for
  other scene wallpapers. Full settings management remains phase four.

## Phase-three runtime and integration

```sh
bash tests/run-scene-runtime-tests.sh
# Optional original scene.json extracted from your own package:
bash tests/run-scene-runtime-tests.sh /absolute/path/to/scene.json
bash tests/run-scene-rendering.sh /absolute/path/to/3799672625
bash tests/run-scene-playback.sh /absolute/path/to/3799672625
bash tests/run-wallpaper-volume.sh /absolute/path/to/3799672625
```

The integration branch is `codex/scene-runtime-integration`. It starts from
`d589f03` (the existing playback/volume work) and includes a snapshot of phase-two
changes plus the runtime. The original working directory is untouched. Merge or
apply this branch as a combined phase-two/three change, not as a second independent
copy of phase two. No installed wallpaper assets are changed.

`SceneWallpaperViewModel` passes the original object JSON, phase-two transform
containers and separate content nodes to `InteractiveWallpaperScene.install`.
Scripts mutate existing transforms; text updates preserve attributed fonts.
Material constants and visibility are uniforms, so script updates do not compile
a new shader each frame. The circular 64-band spectrum is part of the existing
ordered material pipeline, preserving downstream opacity and spin passes.

`SceneScriptRuntime` supports the fixture's 13 distinct scripts: property-local
scope, shared scene/layer objects, `Vec2`/`Vec3`, `WEMath`, init/update/destroy,
settings events and pointer enter/leave/move/down/up/click. Direct scalar and vector
bindings are resolved; `applyUserProperties` is the entry point for phase four.
Exceptions disable only the failing script, with bounded diagnostics. Only WEMath
module imports are supported. This is not a general SceneScript implementation;
JavaScript runs in-process, with no execution-time watchdog for nonterminating
third-party scripts.

The original launcher scripts perform layout, hover scaling, bouncing and drag
position persistence (namespaced by wallpaper path). `launcher1`–`launcher24`
accept absolute macOS application/document paths or HTTP(S) URLs. Local targets
use native macOS icons; clearing them restores package textures. An actual click
is required to launch; scripts cannot open targets during initialization/update.
Windows executables and shell-command strings are unsupported. This branch does
not add a settings editor or guess replacements for Windows launcher targets.

Mouse gestures are observed only over uncovered desktop areas, with coordinates
converted through the actual SKView/camera. Finder remains click-through. Finder
icons overlapping launchers, Mission Control and Spaces require manual validation;
window bounds cannot distinguish individual Finder desktop icons. Monitors are
removed when views detach. Drag releases and clicks are distinguished; pause
cancels a captured gesture.

Audio analysis reads bounded 1024-sample PCM windows on a worker queue at the
existing AVAudioPlayer's current time. It does not open a second playback engine.
The existing main-display audio owner, volume, mute, pause and independent looping
remain in control. Spectrum currently mixes channels to mono and covers package
music, not video soundtracks or other applications' system audio. The rope trail
implements the fixture's rate, velocity, lifetime, color and sizechange operator,
with a bounded particle count and per-segment age-based width.

Automated checks include:

- Script isolation, user-property changes, parent API, click-vs-drag behavior,
  launch gating, shutdown and the actual package's clocks/24 launcher scripts.
- Real sine-wave PCM analysis, silent/paused sources and bounded rope lifetime.
- Integrated parent/font/mask regressions, actual transformed launcher hit tests,
  original bounce animation and GPU spectrum pixel changes when bins change.
- Existing playback, temporary-file cleanup, per-wallpaper volume, sleep/wake
  and single-display audio ownership regressions.

`/tmp/we-phase3-integrated.png` is a QA image over a deliberately low-resolution
preview background. Passing tests does not establish Windows visual parity,
long-duration memory stability or complete support for all scene wallpapers.
