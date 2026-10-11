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

## Per-wallpaper volume

```sh
bash tests/run-wallpaper-volume.sh '/path/to/3799672625'
```

The fixture argument is optional for volume tests. With it, the suite also checks
that scene video and MP3 receive the same effective volume. Without it, it checks
persistence, wallpaper identity/isolation, 0–100% limits, mute/unmute, video player
rebinding, native menu slider actions and control synchronization. It renders the
production controls in light/dark appearances to `/tmp/we-volume-light.png` and
`/tmp/we-volume-dark.png` for visual inspection.

Volumes are saved by standardized wallpaper directory. The same wallpaper on two
screens shares its saved percentage. Different wallpapers retain independent
percentages. The menu has a single overall-volume control;
web wallpaper volume is not exposed because its playback adapter does not support
volume control. Global mute silences all players without changing saved levels.

Audio follows `CGMainDisplayID()` on display-configuration changes, independently
of `selectedScreenId` used for wallpaper editing. Each display retains its own
wallpaper. Only the system main display is audible; changing the system primary
switches audio without changing any wallpaper assignment. A disabled main display
has no audible session. Old manually saved audio-source preferences are ignored.
Display changes reuse existing windows; removed/replaced screen sessions are
explicitly stopped before teardown. The regression suite retains retired scene
models, replaces the same screen repeatedly, sends stale wake events, and verifies
single-source sound plus source switching/disconnect/reconnect behavior.

The volume suite also copies an NSMenu containing the custom slider view (the
previous crash path), checks that decoded controls bind to live volume, and tests
independent wallpaper assignments while transferring sound between main displays.
Dock menus are constructed afresh rather than copying live custom views.

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
music, not video soundtracks. The optional external-player integration described
below adds a separate system-audio source. The rope trail
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

### Clock layout and rope smoothness regression

Text labels retain the packaged fonts and a stable baseline across clock ticks.
The fixture's exported heights (140, 134, 61) match the two fonts' ascender minus
descender at 300 / 72 pixels per point (within one scene pixel). The renderer
uses that raster scale independently of Mac backing scale. Padding no longer
insets the text advance. This is inferred from this export and its Windows
reference, not a verified contract for every Wallpaper Engine version.
The rendering test freezes the displayed time at 02:55:43 for reference comparison.
Center alignment uses half the ascent for the baseline; horizontal alignment uses
SpriteKit glyph bounds rather than typographic advance. The fixed-time capture
was visually compared with the supplied Windows screenshot; pixel-exact parity
is not asserted.

Ropes retain cursor positions every frame independently of the 25 Hz particle
emitter. Bounded Hermite interpolation adds curved spans (up to 16 subdivisions,
about six scene pixels apart on ordinary spans) with at most 4096 rendered segments.
The beam has a narrow core and faint halo; it substitutes for the unavailable
`particle/beam/beam_1` resource. Tests cover turns between emission ticks,
disconnected cursor paths, lifetime/pool bounds and the GPU beam width.
The CPU timing measures the trail alone, not total scene frame time.
`we-live-layout.png` uses actual video; older preview-based images contain a baked
clock and must not be used for clock alignment. GPU output may be 1x or 2x on Retina.

### Background playback recovery

`run-scene-playback.sh` also exercises video-only recovery: the old queue is
released, the replacement retains its layer parent, music and scripts survive,
and extracted media files are reused. Retries back off at 1/2/4 seconds and stop
after three attempts; sleep/pause suspends retries, wake renews the budget, and
60 seconds of healthy playback resets it. A failed item/empty queue injected
while asleep must automatically recover after wake and dismiss the preview.
These checks simulate playback failure and workspace notifications; actual
hardware decoder failure across physical lid-close/wake still requires device QA.

## Phase four: wallpaper settings and daily use

```sh
bash tests/run-scene-runtime-tests.sh
bash tests/run-scene-properties.sh '/path/to/3799672625'
bash tests/run-scene-playback.sh '/path/to/3799672625'
bash tests/run-wallpaper-volume.sh '/path/to/3799672625'
```

The property editor reads every definition from `general.properties`, preserves
workshop order, strips label markup, and supports booleans, sliders, colors, text,
combo boxes, images and macOS shortcuts. Static `text` entries without a value
remain explanatory labels. This fixture has 121 definitions; subordinate dock
settings appear after enabling their controlling switches. Changes save per
wallpaper directory, propagate to matching live scenes, and restore before script
initialization. Reset restores project defaults without modifying the package.
Image overrides update the custom-texture shader; clearing one restores its
original texture. Shortcuts use macOS applications/documents or HTTP(S) links.

Tests cover typed persistence, clamp/step validation, non-executable condition
comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`), rejected invalid
conditions, all fixture conditions, all 121 definitions surviving a metadata
roundtrip, image replacement/reset, settings notifications, and light/dark editor
renders (`/tmp/we-properties-light.png`, `/tmp/we-properties-dark.png`). Conditions
outside this grammar are hidden, not evaluated as JavaScript.

Application focus policies now gate playback without changing the user's manual
pause or mute. Video, music and scripts pause together. System and display sleep
are tracked independently, so one wake event cannot override the other sleep
reason. Newly registered sessions inherit the current focus policy. Settings
changes and audio ownership changes cannot bypass policy mute.

Display assignments use persistent display UUIDs, with migration of connected
screens' legacy numeric IDs. Disabled displays remain disabled on reconnect;
newly discovered displays are enabled. Existing all-Spaces windows retain their
players and script state across Spaces changes. Original desktop images are
saved/restored per display; generated video placeholders only update matching
assignments. A disconnected legacy display can only migrate when its old numeric
ID can still be matched by macOS.

Physical acceptance still required on the target machine: reconnect external
monitors (including changed arrangement/scaling), drag across displays, switch
Spaces/full-screen apps, close/open the lid, and run for several hours while
monitoring memory. Automated tests simulate notifications and session replacement;
they do not establish physical multi-display/Spaces or overnight stability.

### Fast cursor turns between render frames

The wallpaper view now records global/local mouse movement independently of the
render cadence. A bounded 256-event queue feeds elapsed-time samples into the
rope simulation, then rebuilds its geometry once per frame. This retains curved
paths at low wallpaper frame rates without multiplying particle age or rebuilding
SpriteKit segments for every mouse event. Pause/stop clear queued input, stale
samples are discarded, and off-screen samples break the path. Reapplying an
unchanged pause state no longer resets the scene's update clock.

`run-scene-runtime-tests.sh` simulates ten cursor revolutions per second, 240 Hz
mouse input and 30 fps drawing: frame-only sampling produces a maximum radial
error around 74 scene units on a radius-180 circle, while event sampling stays
below 3 (observed 0.77). It also verifies elapsed-time conservation, backlog
bounds and stale-input removal. Hardware cursor feel still depends on the actual
mouse event rate and configured wallpaper FPS.

## Selected release/0.9.0 compatibility features

Selected ideas from `origin/release/0.9.0` (`e069d8d`), including its download
fixes (`dc1bc90`, `4624375`) and TEXS/Scroll runtime (`4254fd5`), are adapted to
the current renderer. The release branch's renderer/audio manager is not merged.

```sh
bash tests/run-steam-download.sh
bash tests/run-scene-compatibility.sh
```

- Downloads use a monotonic 180-second **idle** timeout. Success detection handles
  split output and checks the exact Workshop ID. Graceful termination escalates
  to killing the launched process after five seconds; no blocking pipe EOF read
  follows. Output retention is bounded. A success marker is required before
  importing files, so an old partial folder is not mistaken for success.
- PKG extraction returns zero-indexed `Data` for all consumers.
- TEXS0001/0002/0003 support includes multiple atlases/mipmaps, frame rectangles,
  unequal durations, texture filtering and Retina-independent frame dimensions.
  The existing RGBA, BC/DXT, channel-mask, encoded-image and MP4 code paths remain.
  Atlas counts, frame counts, dimensions and decoded memory are bounded; malformed
  animation metadata falls back to the existing static-image path.
- Scroll is composed with the existing ordered effects and dynamic user bindings.
  Speed uses signed-square conversion; UVs repeat via `fract`. Animation and
  Scroll use the scene's pause-aware update clock, avoiding wake-time jumps.

Download tests use local mock processes (split success, long active download,
ignored SIGTERM, inherited output pipes, mismatched IDs and false-success exits);
no live Steam account/network download is performed. Compatibility tests use
synthetic TEXS containers, reject truncation/nonfinite coordinates, check LZ4 and
BC3 decoding, and verify actual GPU atlas colors and Scroll+opacity output.
Run the existing rendering, playback, volume and runtime suites against the local
3799672625 fixture to check the original wallpaper's behavior.

## External players: artwork and system-audio spectrum

Enable the two independent switches under Settings → General → Other Media
Players. Both default to off. Preferences are stored independently of the legacy
GlobalSettings JSON. The switches apply to scene wallpapers; web/video wallpaper
media integration is outside this implementation.

- Artwork follows the macOS Control Center player, including Chrome/YouTube when
  it publishes artwork. The renderer recognizes the albedo `$mediaThumbnail`
  system binding in a material or instance override. It crops to the authored
  aspect ratio, retains effects/masks/transforms, and restores the packaged image
  when disabled, the player disappears, artwork is missing, or the bridge fails.
  A paused player retains its cover. This is not a screenshot of the player.
- Artwork uses the pinned BSD-3-Clause MediaRemoteAdapter source in `Vendor/`.
  Xcode compiles and bundles it locally; no runtime downloads. The read-only
  stream command is used. Private MediaRemote access can break after macOS
  updates and is unsuitable for an App Store build. Errors expose a retry action;
  the wallpaper continues using its original artwork.
- ScreenCaptureKit supplies audio from all other apps (not just the selected
  Control Center player). No screen output is registered, no microphone is
  captured, and no audio is stored. macOS Screen & System Audio Recording
  permission is required. After granting permission, retry; relaunch if macOS
  requests it. Protected content may not supply capturable audio.
- System audio replaces the package-music spectrum while enabled, even when
  access fails (silence is shown). Disable it to restore the package analyzer.
  This does not mute the wallpaper's own music; its volume remains independent.
- One bridge and one capture stream are shared across displays. All scene
  consumers paused/stopped or system sleep releases them; resume reconnects.
  A stalled audio callback expires in 300 ms. Revocation/capture errors display a
  status and require retry, avoiding repeated permission requests.

Automated checks (no recording permission required):

```sh
bash tests/run-external-media.sh
bash tests/run-media-settings-ui.sh
bash tests/run-scene-rendering.sh '/path/to/3799672625'
```

These exercise opt-in defaults, shared resource ownership, pause/resume/retry,
preference persistence, artwork replacement/reset, bounded image decoding,
invalid JSON, wide-image cropping, real PCM FFT, antiphase stereo, planar and
interleaved CoreMedia conversion, silence expiry, and the original fixture's GPU
cover mask with a replacement image. UI snapshots are written to
`/tmp/we-media-settings-{light,dark}.png` for visual inspection.

Optional live integration test, with an actual Control Center player and artwork:

```sh
bash tests/run-external-media.sh --live-now-playing
```

This builds a temporary app bundle and checks the production Swift reader plus
bundled adapter deliver decoded artwork. It reads no screen pixels and sends no
playback commands. Live ScreenCaptureKit still needs manual verification in the
built app: grant permission, play/pause Chrome YouTube, switch songs/players,
check silence/revocation/retry, and pause/resume/sleep with multiple displays.

### Bridge build sandbox regression

Validate from a fresh DerivedData directory outside `/tmp`, since temporary-path
access can mask missing Xcode script output declarations:

```sh
xcodebuild -project 'Open Wallpaper Engine.xcodeproj' \
  -scheme 'Open Wallpaper Engine' -configuration Debug \
  -derivedDataPath build/media-sandbox-validation \
  ENABLE_USER_SCRIPT_SANDBOXING=YES CODE_SIGNING_ALLOWED=NO build
```

The bridge compiles/signs in `TEMP_DIR`, then copies the signed files to exact
paths declared in `scripts/media-bridge-outputs.xcfilelist`. Keep that list in
sync when changing the bundle layout; a directory output alone does not grant
recursive write access. Verify the copied framework with `codesign --verify
--strict` as well.
