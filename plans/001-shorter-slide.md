# 001 — Shorter hotkey slide in and out

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: HIGH
- **Category**: Purpose & frequency, Easing & duration
- **Estimated scope**: 2 files, about 10 lines

## Problem

The panel opens from a global hotkey, tens of times a day. Its slide in springs with response 0.42 and damping 0.74: about 0.7 s to settle with a visible overshoot. UI motion should stay under 300 ms, and exits should be faster than entries.

```swift
// Sources/SidekickCore/Spring.swift:14-17 — current
    /// The panel arriving from the edge: a little bounce, as asked for.
    public static let arrive = Spring(response: 0.42, damping: 0.74)
    /// The panel leaving: quick and calm, no overshoot.
    public static let leave = Spring(response: 0.3, damping: 1)
```

## Target

```swift
    /// The panel arriving from the edge: quick, with a hint of bounce. It opens from a hotkey many
    /// times a day, so it settles in about 0.4 s.
    public static let arrive = Spring(response: 0.30, damping: 0.86)
    /// The panel leaving: faster than it came, no overshoot.
    public static let leave = Spring(response: 0.22, damping: 1)
```

## Repo conventions to follow

- The app reads these through `PanelController.arriveAnimation` and `leaveAnimation` (or `PanelMotion.arrive` and `.leave` after plan 009). Change only the Core values.

## Steps

1. Edit `Sources/SidekickCore/Spring.swift` as in the target.
2. Edit the spring check in `Sources/sidekick-checks/main.swift` (search `arrive spring overshoots a little`). Replace the two checks:
   ```swift
   check(peak > 100.05 && peak < 103, "arrive spring overshoots a hint", "peak \(peak)")
   check(Double(frames) / 120 < 0.8, "arrive spring settles within 0.8 s", "\(Double(frames) / 120)")
   ```
   and rename nothing else.

## Boundaries

- Do NOT change `grow` or `fade`.
- Do NOT add a fade or scale to the slide. Jonni asked for slide only.

## Verification

- **Mechanical**: `scripts/test.sh` prints `CHECKS PASS`.
- **Feel check**: in the VM recording (`build/vm-out/probe.mov`), pull frames at 60 fps around the first open: `ffmpeg -ss <t> -t 0.6 -i probe.mov -vf "fps=60,crop=1300:180:2796:30,scale=520:-1,tile=4x9" sheet.png`. The card reaches its place in about 0.3 s, overshoots by only a few points, and is still by 0.45 s. The exit is visibly quicker than the entry.
- **Done when**: checks pass and the frames show the shorter settle.
