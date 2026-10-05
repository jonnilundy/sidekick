# 002 — Only a sent question rises; revealed history fades

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: MEDIUM
- **Category**: Physicality & origin
- **Estimated scope**: 1 file, about 15 lines

## Problem

Every turn uses the "rise out of the field" insertion. When the user pulls the history open, all earlier turns are inserted at once and each rises 36 pt, so revealing history looks like sending many questions.

```swift
// Sources/SidekickApp/PanelView.swift:74-80 — current
                ForEach(model.visibleTurns) { turn in
                    TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id)
                        // A sent question rises out of the field into its place.
                        .transition(.asymmetric(
                            insertion: .offset(y: 36).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)).combined(with: .opacity),
                            removal: .opacity))
                }
```

## Target

```swift
// in enum PanelMotion (PanelView.swift)
    /// A sent question rises out of the field into its place.
    static let rise = AnyTransition.asymmetric(
        insertion: .offset(y: 36).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)).combined(with: .opacity),
        removal: .opacity)

// in PanelCard.transcript
                ForEach(model.visibleTurns) { turn in
                    TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id)
                        // Only the question just sent rises; turns revealed by the pull fade in where they are.
                        .transition(isJustSent(turn) ? PanelMotion.rise : .opacity)
                }

// a helper in PanelCard
    private func isJustSent(_ turn: Conversation.Turn) -> Bool {
        turn.id == conversation.turns.last?.id && turn.status == .running
    }
```

## Steps

1. Add `static let rise` to `enum PanelMotion` (if the enum is missing, create `enum PanelMotion { static let rise = ... }` at the top of `PanelView.swift`).
2. Change the `.transition` in the ForEach as in the target, and add `isJustSent` to `PanelCard`.

## Boundaries

- Do NOT change `TurnView`.

## Verification

- **Mechanical**: `scripts/test.sh` passes; VM probe passes (`a real drag down on the grabber shows the history`).
- **Feel check**: in the VM recording, at the pull open (screenshot `11-pulled-open`), the earlier turns fade in place without moving up. On a send, the new question still rises.
- **Done when**: history reveal has no upward motion.
