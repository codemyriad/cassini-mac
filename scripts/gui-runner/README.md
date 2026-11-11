# Dedicated GUI runner

These infrastructure helpers belong to the dedicated standard account (UID503),
not to the app bundle. The operator's replay record and LaunchAgent snapshots are
in `~/coordination/MACHOST-GUI-RUNNER.md` and `~/coordination/gui-runner/` on the host.

The display helper keeps a1280x960/1920x1200 unscaled virtual display alive in Aqua.
The runner startup script requires the real console account and waits on display
readiness events. The job hook checks the session and mutes output. Only one
runner carries `cm-mac-gui`, preserving the full Actions queue while serializing
all desktop use. The xcodebuild wrapper shares the existing three heavy slots
through the allocator's optional `CASSINI_HEAVY_LOCK_ROOT` setting; the default
allocator behavior is unchanged.

Build the display helper with `xcrun clang -fobjc-arc -Wall -Werror -framework
Cocoa -framework CoreGraphics display.m -o cassini-gui-display`. Its private
CoreGraphics API must be qualified after OS upgrades; a missing active display
fails startup instead of accepting a headless session.

The new `CM_MAC_GUI_RUNNER` variable is opt-in. Without it, screenshots and
Library boards use hosted macOS. Fork pull requests always use hosted fallback.
Do not enable it until a coordinator-controlled reboot establishes the actual
Aqua account, both LaunchAgents start, mute is confirmed, and the unchanged
screenshots/boards checks pass. Never spoof RUNNER_ENVIRONMENT.

Browser setup retains its disposable-host TCC provisioning and stays hosted.
Native profiling retains its disposable-host global indexing/profiler setup.
Other app/architecture lanes await separate qualification. Production signing
and notarization workflows are not routed here. No Apple ID or app signing keys
are installed. Local auto-login uses only the root-private account password;
`install-autologin.py` is an operator replay tool, never an Actions step.
