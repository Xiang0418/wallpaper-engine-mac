Vendored from https://github.com/ungive/mediaremote-adapter
Commit: 797729d9b16316dc313844476c153d7a107ca0df
License: BSD-3-Clause (see LICENSE). Original source is unmodified.

Built locally by scripts/build-media-bridge.sh; no binary download or runtime
installation. Only the read-only stream command is invoked by the app. The
upstream bridge loads private MediaRemote via the system Perl interpreter;
this compatibility workaround can break with macOS updates and is not an
App Store API. Failure clears external artwork and preserves the wallpaper.
