# 008 — One trailing button that morphs its symbol

- **Status**: TODO
- **Commit**: 9ef3970
- **Severity**: LOW
- **Category**: Cohesion & tokens
- **Estimated scope**: 1 file, about 12 lines

## Problem

On every question the Stop button and the Reset button swap as two separate views, each popping in from scale 0.6. One control whose symbol morphs reads as one thing changing state.

```swift
// Sources/SidekickApp/PanelView.swift:170-179 — current
    @ViewBuilder private var trailingButton: some View {
        if conversation.isRunning {
            IconButton(symbol: "stop.fill", help: "Stop (⌘.)") { conversation.stop() }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if !conversation.isEmpty && !model.isCompact {
            IconButton(symbol: "arrow.counterclockwise", help: "Reset: start a fresh session (⌘N)") { model.onNew?() }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
```

`IconButton` (same file, `struct IconButton`) already has `.contentTransition(.symbolEffect(.replace))` on its image.

## Target

```swift
    /// One button: Stop while an answer runs, Reset after. The symbol morphs between them.
    @ViewBuilder private var trailingButton: some View {
        let running = conversation.isRunning
        if running || (!conversation.isEmpty && !model.isCompact) {
            IconButton(symbol: running ? "stop.fill" : "arrow.counterclockwise",
                       help: running ? "Stop (⌘.)" : "Reset: start a fresh session (⌘N)") {
                if conversation.isRunning { conversation.stop() } else { model.onNew?() }
            }
            .animation(.snappy(duration: 0.2), value: running)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
```

## Steps

1. Replace `trailingButton` with the target.

## Boundaries

- Do NOT change `IconButton`.

## Verification

- **Mechanical**: `scripts/test.sh` passes; the VM probe passes (`stop ends the turn`, `⌘N clears the conversation`).
- **Feel check**: in the VM recording, when an answer finishes the square morphs into the circular arrow in place; nothing pops.
- **Done when**: one button view, symbol morphs.
