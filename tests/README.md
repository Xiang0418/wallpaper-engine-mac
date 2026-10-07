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
  Clock values remain exported values until phase-three scripts are implemented.
- Built-in solid layers and instance textures; four additive flares; red-channel
  opacity masks; ordered opacity/spin/custom-texture passes; the fixture's round
  frame shader configuration. The spectrum shader draws its zero-input state,
  without claiming audio reactivity. Spin uses SpriteKit scene time and pauses
  with the scene. Unknown effects are reported through `renderingWarnings`.
- Project defaults resolve direct scalar/color bindings. Missing bindings and
  scripts retain stored values. Expression evaluation, scalar-to-vector property
  conversion, editable settings and persistence are not implemented here.
- Font/texture caches belong to the renderer and are cleared on stop/replacement.

Limits requiring further work or external validation:

- This is a port of the tested fixture's effects, not a general shader engine.
  Other frame combinations, perspective/3D cameras, text wrapping/spacing and
  animated texture sequences are not covered. Text baselines and blend appearance
  still need comparison with the original Windows renderer.
- The missing `particle/beam/beam_1` engine texture has a procedural approximation;
  the original resource is not bundled. Particle simulation remains phase three.
- Windows reference screenshots and original engine resources were not available,
  so these tests do not establish pixel-identical parity or complete support for
  other scene wallpapers. Scripts, interactive launchers and live clocks remain
  phase three; full settings management remains phase four.
