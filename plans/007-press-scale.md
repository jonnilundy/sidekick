# 007 — Subtle press scale

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: LOW
- **Category**: Physicality & origin
- **Estimated scope**: 1 file, 2 lines

## Problem

Buttons shrink to 0.9 on press. Press feedback should be subtle: 0.95 to 0.98, about 160 ms.

```swift
// Sources/SidekickApp/PanelView.swift:326-331 — current
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}
```

## Target

```swift
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(PanelMotion.press, value: configuration.isPressed)
```
with `PanelMotion.press = Animation.spring(response: 0.16, dampingFraction: 1)` (set the value in `enum PanelMotion`; if plan 009 is not done, write `.spring(response: 0.16, dampingFraction: 1)` inline).

## Steps

1. Change the scale to 0.97.
2. Set the press spring response to 0.16.

## Boundaries

- Only `PressScale` and `PanelMotion.press`.

## Verification

- **Mechanical**: `scripts/test.sh` passes.
- **Feel check**: hard to see in a recording; the value is from the audit catalog (0.95 to 0.98).
- **Done when**: the values match.
