# Embedded app and browser harness completion

This area combines #236 and #238 on main `5562b8b`. The merged queue acceptance hook is retained.

| Conversion | Completion evidence | Mutation |
| --- | --- | --- |
| Companion startup | Connected peer and prepared companion | [Drop observation](observation.patch) |
| App browser return | Published peer and capture state | [Drop observation](observation.patch) |
| Live-folder save | Capture retirement | [Drop observation](observation.patch) |
| Trash queue and Library state | Observable preparation and one persisted-state read | [Drop observation](observation.patch) |
| Native fixture teardown | Real child exit after stdin EOF | [Drop exit event](child-exit.patch) |
| Microphone silence | Hidden at 19.98 s, visible at 20 s, cleared by sound | [Change boundary](silence.patch) |
| Generated browser receiver and audio diagnostics | Connection event and rendered-frame snapshot | [Drop receiver event](receiver-event.patch) |
| Hosted display setup | Readback after configuration command exit | Successful command returning a wrong resolution |

All eight mutations are rejected. Fixed headless cases pass, including actual child-process exit. The source-extracted Swift probes use generated state and a one-second failure bound. Node drives the actual generated page script with peer events. Display validation supplies a private synthetic displayplacer executable.

[Mutation receipts](mutations.log) preserve the individual failures. Full before/after logs and replay scripts are in `~/coordination/evidence/big-mac-d88/areas/app`. All 41 CI contract tests pass. Hosted app, Chromium and sandbox checks remain required on this area's head.

[The #236 source and prior proof](https://github.com/codemyriad/cassini-mac/tree/258d3a283fe3afc2a0e9cee693b839b9bbd26973) and [the #238 source and prior proof](https://github.com/codemyriad/cassini-mac/tree/279219ed7bc04568de18c71bb4be14c94f1da9c3) remain preserved in history.
