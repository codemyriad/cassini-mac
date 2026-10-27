# Board-size capture spike (W1-M4)

Goal: real 1120×720 PNGs of the whole window, unified toolbar and attached native
sheet, captured exclusively on a GitHub-hosted runner. This is capture machinery;
the document UI is not a claim to implement the Library boards.

Preferred attempt: enlarge the ephemeral macos-15 display before app launch using
[displayplacer's documented interface](https://github.com/jakehilborn/displayplacer#usage).
`hosted-display.py` logs all available modes, selects the smallest listed unscaled
mode at least 1280×900, applies it, then verifies readback rather than trusting a
possibly unsupported/fallback mode. It refuses non-hosted execution. The workflow
also preserves system_profiler output and the selected mode in artifacts.

`-CassiniScreenshotSize 1120x720` selects a board-size Debug fixture window. Both
window edges and exact PNG dimensions are asserted. The same XCUITest capture
includes the native toolbar and attached sheet; Return/Esc role tests still run.
The regular W1-M3 job keeps its existing 960×640 default.

Two independent macos-15 jobs repeat the mode selection and UI tests, to check
that the result is reproducible on fresh hosts rather than relying on one saved
display state. There is no Screen Recording consent request, TCC change, private
window subclass or bitmap compositing in this approach. Local work is compile-only.

Time box: this working session. If no suitable mode exists, the coordinator's next
preferences are an unconstrained offscreen window, then NSThemeFrame rendering.
Results and the chosen recommendation will be in coordination REPLIES-MAC.md and
STATUS-MAC.md, with exact heads and artifact links.
