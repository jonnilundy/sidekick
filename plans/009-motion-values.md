# 009 — One set of motion values, no double animation

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: LOW
- **Category**: Cohesion & tokens
- **Estimated scope**: 3 files, about 30 lines

## Problem

Spring values are typed inline in six places, and the send unfold is applied twice.

```swift
// Sources/SidekickApp/PanelView.swift:11 — current
enum PanelMotion {
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.88)
}
// Sources/SidekickApp/PanelView.swift:58 — current (implicit, duplicates the withAnimation in onSubmit at :109)
        .animation(PanelMotion.unfold, value: showsTranscript)
// Sources/SidekickApp/PanelView.swift:95 — current
        .animation(.spring(response: Spring.grow.response, dampingFraction: Spring.grow.damping), value: transcriptHeight)
// Sources/SidekickApp/PanelView.swift:157 — current
        let animation: Animation = abs(velocity) > 300 ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.38, dampingFraction: 1)
// Sources/SidekickApp/PanelView.swift:330 — current (PressScale)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
// Sources/SidekickApp/AnswerView.swift:200 — current (DetailsBlock)
                withAnimation(.spring(response: 0.3, dampingFraction: 1)) { open.toggle() }
// Sources/SidekickApp/PanelController.swift:194-200 — current
    private var arriveAnimation: Animation {
        model.reduceMotion ? .easeOut(duration: 0.18) : .spring(response: Spring.arrive.response, dampingFraction: Spring.arrive.damping)
    }
    private var leaveAnimation: Animation {
        model.reduceMotion ? .easeIn(duration: 0.14) : .spring(response: Spring.leave.response, dampingFraction: Spring.leave.damping)
    }
```

## Target

All values in one enum. Values are UNCHANGED here (other plans change them); this plan only moves them.

```swift
// Sources/SidekickApp/PanelView.swift — replaces the current PanelMotion
/// Every motion value in the panel. Spring values for the slide live in SidekickCore's `Spring` so
/// checks can test them; this turns them into SwiftUI animations.
enum PanelMotion {
    /// The hotkey slide in from the screen edge.
    static let arrive = Animation.spring(response: Spring.arrive.response, dampingFraction: Spring.arrive.damping)
    /// The slide back out.
    static let leave = Animation.spring(response: Spring.leave.response, dampingFraction: Spring.leave.damping)
    /// Width, height and content changing together: a send, compact to full.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Transcript height changes.
    static let grow = Animation.spring(response: Spring.grow.response, dampingFraction: Spring.grow.damping)
    /// Pull release after a flick, and after a slow release.
    static let pullFlick = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let pullSettle = Animation.spring(response: 0.38, dampingFraction: 1)
    /// Button press feedback.
    static let press = Animation.spring(response: 0.18, dampingFraction: 1)
    /// A details section opening or closing.
    static let disclose = Animation.spring(response: 0.3, dampingFraction: 1)
    /// Reduced motion: fades instead of slides.
    static let fadeIn = Animation.easeOut(duration: 0.18)
    static let fadeOut = Animation.easeIn(duration: 0.14)
}
```

## Repo conventions to follow

- Comments are short plain sentences, no dashes as punctuation. See `Sources/SidekickApp/PanelView.swift:10`.
- Core keeps the slide springs (`Sources/SidekickCore/Spring.swift`) because `sidekick-checks` tests their overshoot.

## Steps

1. Replace `enum PanelMotion` in `Sources/SidekickApp/PanelView.swift` with the target above.
2. `PanelView.swift:58`: delete the line `.animation(PanelMotion.unfold, value: showsTranscript)`. The `withAnimation(PanelMotion.unfold)` in `onSubmit` already animates a send.
3. `PanelView.swift:95`: replace the spring with `PanelMotion.grow`: `.animation(PanelMotion.grow, value: transcriptHeight)`.
4. `PanelView.swift:157`: `let animation: Animation = abs(velocity) > 300 ? PanelMotion.pullFlick : PanelMotion.pullSettle`.
5. `PanelView.swift:330`: `.animation(PanelMotion.press, value: configuration.isPressed)`.
6. `AnswerView.swift:200`: `withAnimation(PanelMotion.disclose) { open.toggle() }`.
7. `PanelController.swift:194-200`: `arriveAnimation` returns `model.reduceMotion ? PanelMotion.fadeIn : PanelMotion.arrive`; `leaveAnimation` returns `model.reduceMotion ? PanelMotion.fadeOut : PanelMotion.leave`.

## Boundaries

- Do NOT change any value. Behavior must be identical after this plan.
- Do NOT touch `Sources/SidekickCore`.
- If a quoted line does not match the code, STOP and report.

## Verification

- **Mechanical**: `scripts/test.sh` prints `CHECKS PASS`. `grep -n "spring(response" Sources/SidekickApp/*.swift` shows matches only inside `enum PanelMotion`.
- **Feel check**: none needed; values are unchanged. In the VM recording, a send still unfolds as before.
- **Done when**: no inline spring values remain outside `PanelMotion`, and the implicit unfold at line 58 is gone.
