# 003 — Reduced motion covers unfold, rise and pull

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: MEDIUM
- **Category**: Accessibility
- **Estimated scope**: 1 file, about 15 lines

## Problem

With Reduce Motion on, only the slide becomes a fade. The width spring, the 36 pt rise of a sent question, the pull springs and the height spring still move. Reduced motion means fewer and gentler animations: keep opacity, drop movement.

Locations in `Sources/SidekickApp/PanelView.swift`: the width `.animation(PanelMotion.unfold, value: model.isCompact)` in `PanelView.body`; the turn `.transition` in `PanelCard.transcript`; `withAnimation(PanelMotion.unfold) { model.submit() }` in `inputRow`; the animation choice in `finishPull`; `.animation(... value: transcriptHeight)` in `transcript`. `model.reduceMotion` (a `PanelModel` property, kept current by `PanelController`) is the switch.

## Target

- Width: `.animation(model.reduceMotion ? nil : PanelMotion.unfold, value: model.isCompact)`
- Turn transition: `model.reduceMotion ? .opacity : (isJustSent(turn) ? PanelMotion.rise : .opacity)` (if plan 002 is not done: `model.reduceMotion ? .opacity : <current transition>`)
- Submit: `withAnimation(model.reduceMotion ? PanelMotion.fadeIn : PanelMotion.unfold) { model.submit() }` (`PanelMotion.fadeIn = Animation.easeOut(duration: 0.18)`; inline it if plan 009 is not done)
- Pull: in `finishPull`, `let animation: Animation = model.reduceMotion ? PanelMotion.fadeIn : <current choice>`
- Height: when `model.reduceMotion`, the height change is not animated (pass `nil` where the height animation is chosen).

## Steps

1. Apply each target line at its location.

## Boundaries

- Keep opacity changes: they help comprehension.
- Do NOT touch the Thinking shimmer (it already respects `accessibilityReduceMotion`).

## Verification

- **Mechanical**: `scripts/test.sh` passes; VM probe passes (its reduced motion step).
- **Feel check**: add nothing to the probe. Read the diff: every `withAnimation`, `.animation` and `.transition` in `PanelView.swift` either has a `reduceMotion` branch or only changes opacity or color.
- **Done when**: that read passes.
