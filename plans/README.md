# Motion plans

Written by the improve-animations audit on 2026-10-05 at commit 9ef3970. Each plan is self-contained.

| # | Title | Severity | Status |
| --- | --- | --- | --- |
| 009 | One set of motion values, no double animation | LOW | DONE |
| 001 | Shorter hotkey slide in and out | HIGH | DONE |
| 006 | Reduced motion hide eases out | LOW | DONE |
| 007 | Subtle press scale | LOW | DONE |
| 008 | One trailing button that morphs its symbol | LOW | DONE |
| 002 | Only a sent question rises; revealed history fades | MEDIUM | DONE |
| 003 | Reduced motion covers unfold, rise and pull | MEDIUM | TODO |
| 004 | No height spring on every streamed batch | MEDIUM | TODO |
| 005 | Pull release keeps the finger's speed | MEDIUM | TODO |

Run them in this order: 009, 001, 006, 007, 008, 002, 003, 004, 005.

- 009 first: it creates `PanelMotion` values the others use. Each plan says what to do if 009 is not done.
- 003 after 002: 003 adds a reduced motion branch to the transition 002 introduces.
- 004 and 005 both edit `PanelCard` in `Sources/SidekickApp/PanelView.swift`, in different functions.

Every plan: run `scripts/test.sh` after it (expect `CHECKS PASS`). After the last plan: `scripts/build-app.sh`, then `VM_DIR=sidekick-motion scripts/vm-run.sh` (expect `PROBE PASS`). Never run the app on Jonni's Mac; windows run only in the VM.
