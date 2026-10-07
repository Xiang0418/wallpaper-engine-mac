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

Display Settings selects one audio-source screen, persisted across restart. Other
screens stay silent even when they show a different wallpaper. If the chosen
screen disconnects or is disabled, no other screen automatically takes over.
Display changes reuse existing windows; removed/replaced screen sessions are
explicitly stopped before teardown. The regression suite retains retired scene
models, replaces the same screen repeatedly, sends stale wake events, and verifies
single-source sound plus source switching/disconnect/reconnect behavior.
