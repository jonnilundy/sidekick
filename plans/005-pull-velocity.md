# 005 — Pull release keeps the finger's speed

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: MEDIUM
- **Category**: Interruptibility
- **Estimated scope**: 1 file, about 20 lines

## Problem

When the grabber is let go, the history opens or closes with a spring that starts at rest. The drag's speed is dropped, so there is a seam between dragging and animating. The release must continue at the finger's velocity.

```swift
// Sources/SidekickApp/PanelView.swift — current, PanelCard.finishPull
    private func finishPull(translation: CGFloat, velocity: CGFloat) {
        let outcome = HistoryDrag.outcome(translation: Double(translation), velocity: Double(velocity), isOpen: model.historyOpen)
        // A flick hands its speed to the spring, a slow release settles calmly.
        let animation: Animation = abs(velocity) > 300 ? PanelMotion.pullFlick : PanelMotion.pullSettle
        withAnimation(animation) { ... }
```

## Target

SwiftUI's `interpolatingSpring(duration:bounce:initialVelocity:)` takes a relative velocity: the gesture velocity divided by the distance still to travel (`relative = velocity / (target - current)`).

```swift
    private func finishPull(translation: CGFloat, velocity: CGFloat) {
        let outcome = HistoryDrag.outcome(translation: Double(translation), velocity: Double(velocity), isOpen: model.historyOpen)
        // Hand the finger's speed to the spring, so there is no seam between the drag and the motion.
        // Opening or closing moves about a screenful of history; springing back moves the stretch.
        let distance: CGFloat
        switch outcome {
        case .open: distance = max(120, min(model.maxTranscriptHeight, 400))
        case .close: distance = -max(120, min(transcriptHeight, model.maxTranscriptHeight))
        case .stay: distance = -stretch
        }
        let relative = abs(distance) < 1 ? 0 : max(-12, min(12, velocity / distance))
        let animation: Animation = model.reduceMotion
            ? PanelMotion.fadeIn
            : .interpolatingSpring(duration: 0.4, bounce: abs(velocity) > 300 ? 0.15 : 0, initialVelocity: relative)
        withAnimation(animation) { ... unchanged ... }
```

Keep the body of `withAnimation` and the two lines after it unchanged. If plan 003 is not done, drop the `model.reduceMotion` branch. `PanelMotion.pullFlick` and `.pullSettle` become unused: delete them from `enum PanelMotion`.

## Steps

1. Replace the top of `finishPull` as in the target.
2. Delete `pullFlick` and `pullSettle` from `PanelMotion` if nothing else uses them.

## Boundaries

- Do NOT change `HistoryDrag` in Core or its checks.

## Verification

- **Mechanical**: `scripts/test.sh` passes; VM probe passes (`a real drag down on the grabber shows the history`, `a real drag up tucks it away`, `a short pull springs back shut`).
- **Feel check**: a gesture hand-off can only be judged by hand. Note in the report that Jonni should flick the grabber on his Mac: the history should keep moving at the flick's speed with no pause at release.
- **Done when**: probe passes.
