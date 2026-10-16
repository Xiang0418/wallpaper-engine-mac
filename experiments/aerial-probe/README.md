# Aerial lock-screen probe

Applied 2026-10-12. Backs up the original 445 MB Tahoe Day movie and the entire wallpaper Store/Index.plist before replacing the movie. SHA-256 checks are recorded in the backup manifest.

Backup: `build/aerial-probe/20261012-183658/` (do not clean this build directory until restoration).

After the user unlocked, reselected Tahoe Day on the built-in display and Automatic screen saver. The system settings thumbnail visibly shows clean circles and AERIAL VIDEO TEST with no stripes. Lock-screen behavior still awaits user observation. Idle timeout and password requirements were not changed. The test movie is 1280×720 HEVC, silent, 180 seconds; blue background, moving turquoise circles and “AERIAL VIDEO TEST”. Unlike the earlier probe, there is no 90-second auto-exit and the replacement persists until restoration. A 3-second pattern is repeated inside the file; endless playback by macOS is not established.

Validation: generated file duration/audio checked, installed file hash matched, system UI confirmed Tahoe Day and Automatic. Actual lock visibility and repeat lock/unlock behavior await user observation. Initial 8-bit HEVC produced a striped settings thumbnail. Re-encoded with Main10 and temporal sub-layers using the reviewed source below; 5400 frames, 180 seconds, one video track, no audio, tscl/tsas markers present, extracted frame visually verified; do not mark lock-screen success based on desktop or settings previews.

## Restore

Run from project root, outside the Codex filesystem sandbox (no sudo needed):

```sh
python3 experiments/aerial-probe/restore.py
```

The script validates backups, restores both the original movie and Index.plist, and restarts the current user's WallpaperAerialsExtension and WallpaperAgent. Keep the backup until restored appearance is verified. Restoring Index.plist also reverts any wallpaper selections made since this backup.

## Test

Lock using Control+Command+Q, leave input untouched for 10–15 seconds, observe moving circles and test label. Unlock and report whether it played, stayed still, or went black. Then evaluate repeated locks separately. Do not mistake the original character wallpaper or a still poster for success.

Encoder reference (downloaded and inspected, build-only): https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix/blob/main/encode_temporal.swift

User confirmed the Main10 AERIAL VIDEO TEST was visible and animated while locked, and unlock worked. Next experiment: currently selected Atri video, workshop 3817766204, source 3840×2174 / 4.007 seconds, repeated 45 times and encoded Main10 with temporal layers. Original source remains untouched.

Character version installed: `build/aerial-probe/character-aerial-main10.mov`, 180.375 seconds, 3840×2174, no audio. Encoded one cycle then passthrough repeated; tscl/tsas markers retained. Output frame visually checked; system Aerial settings thumbnail shows the character under Tahoe Day. User lock/unlock validation pending. Apple original backup remains unchanged.

2026-10-12 follow-up: user confirmed the character animates while locked and two consecutive
lock/unlock cycles work. The production integration now lives under Services/LockScreen.
The verified original movie and Index backup have been migrated to
`~/Library/Application Support/Open Wallpaper Engine/LockScreenSync/`.
After enabling the integrated app, use its disable/restore control; the old probe's applied
hash no longer tracks future app-generated movies. The experiment backups remain available.
