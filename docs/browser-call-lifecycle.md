# D33 call lifecycle adoption

Shared input: protocol merge
`bb13da92fa8c3192bb6d9b8444acd3197c772d62`, unchanged extension 0.2.2.
The reviewed snapshot is vendored verbatim. No shared extension patch or store
package belongs in this app change.

The per-session `BrowserCallLifecycle` uses the shared 2-second call-end grace
and 120-second browser-return grace. Closed-tab evidence is sticky. The return
deadline is checked before accepting renewed audio; another tab and an absent
PCM transport cannot restore a source. The device owner supplies the actual
source, so failed fallback or restoration staging cannot silently change it.
The production value type passes all 15 unchanged shared vectors (55 steps).

This adoption is in progress. Before enabling `keepOnNavigation`, the app must
parse capability-scoped `pageState`, preserve legacy peer behavior, integrate
fallback/restoration with real track transactions and producer loss timestamps,
and thread terminal reasons through Stop, disk failure and Quit. The actual
writer must reserve the final event slot, atomically persist exactly one terminal
event after finalized PCM and cover native as well as browser sessions.
The reader must preserve the source state across an end event and accept
`restored` only for a browser source.

Required hosted integration checks include same-folder restoration, The others
off, two independent captures, native staging failures, deadline-boundary return,
closed tabs without computer-sound fallback and durable terminal-event timing.
The standalone policy/vector check is preparation, not product completion.
