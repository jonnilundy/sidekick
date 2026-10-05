# 004 — No height spring on every streamed batch

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: MEDIUM
- **Category**: Performance
- **Estimated scope**: 1 file, about 15 lines

## Problem

While an answer streams, text arrives in batches 30 times a second. Each batch changes `transcriptHeight`, and the implicit spring re-runs a layout of the whole transcript every frame. Size animation is layout work; motion should prefer transform and opacity. The panel's own stall timing (`scripts/vm-run.sh 'scripts/vm-test.sh worst'`, line `probe: worst-big ... longest main-thread stall`) was 145 ms before this plan.

```swift
// Sources/SidekickApp/PanelView.swift — current, in PanelCard.transcript
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { transcriptHeight = $0 }
        ...
        .animation(PanelMotion.grow, value: transcriptHeight)   // or the inline spring before plan 009
```

## Target

Remove the implicit `.animation(..., value: transcriptHeight)`. Set the height explicitly in `onGeometryChange`: small growth during a running answer is applied at once (the bottom scroll anchor keeps the newest line in view, so it reads as text arriving); every other change springs.

```swift
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { setTranscriptHeight($0) }

    /// Streaming growth lands at once: animating every batch would lay the transcript out each frame.
    /// Sends, collapses and reveals still spring.
    private func setTranscriptHeight(_ height: CGFloat) {
        let growth = height - transcriptHeight
        if model.reduceMotion || (conversation.isRunning && growth > 0 && growth < 80) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { transcriptHeight = height }
        } else {
            withAnimation(PanelMotion.grow) { transcriptHeight = height }
        }
    }
```

(`PanelMotion.grow = Animation.spring(response: 0.32, dampingFraction: 1)`; inline it if plan 009 is not done. If plan 003 is not done, drop the `model.reduceMotion ||` part.)

## Steps

1. Delete the `.animation(..., value: transcriptHeight)` modifier on the transcript.
2. Replace the `onGeometryChange` closure on the transcript content and add `setTranscriptHeight` to `PanelCard`.

## Boundaries

- Do NOT change the bottom scroll anchor or the frame height formula.

## Verification

- **Mechanical**: `scripts/test.sh` passes; VM probe passes (`the card grows for the answer`).
- **Feel check**: run `VM_DIR=sidekick-motion scripts/vm-run.sh 'scripts/vm-test.sh worst'` and compare `longest main-thread stall` with 145 ms; report the new number. In `build/vm-out/probe.mov`, a streamed answer grows line by line with no lag behind the text, and a send still unfolds smoothly.
- **Done when**: probe passes and the stall number is reported.
