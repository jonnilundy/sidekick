# 006 — Reduced motion hide eases out

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: LOW
- **Category**: Easing & duration
- **Estimated scope**: 1 file, 1 line

## Problem

With Reduce Motion on, the panel hides with `.easeIn(duration: 0.14)`. Ease in on UI starts slow, at the moment the user watches.

```swift
// Sources/SidekickApp/PanelController.swift:199 — current (before plan 009)
        model.reduceMotion ? .easeIn(duration: 0.14) : .spring(...)
// or, after plan 009, Sources/SidekickApp/PanelView.swift in enum PanelMotion:
    static let fadeOut = Animation.easeIn(duration: 0.14)
```

## Target

`.easeOut(duration: 0.14)` in whichever of the two places holds it.

## Steps

1. If `PanelMotion.fadeOut` exists, set it to `Animation.easeOut(duration: 0.14)`. Otherwise change `.easeIn(duration: 0.14)` at `PanelController.swift:199` to `.easeOut(duration: 0.14)`.

## Boundaries

- Only this value.

## Verification

- **Mechanical**: `scripts/test.sh` passes; `grep -rn "easeIn(" Sources/SidekickApp` finds nothing.
- **Feel check**: the probe's reduced motion step still hides and shows (`hides with reduced motion` passes).
- **Done when**: no ease in remains in the app.
