# 010 — break-ui fixes

- **Status**: TODO, waiting for Jonni to kick off
- **Source**: the break-ui pass of 2026-10-05 (`scripts/vm-run.sh 'scripts/vm-test.sh worst'`)
- **Severity**: mixed, worst first below

The worst-case data that found these lives in `scripts/fake-claude` (questions with `worst text`, `worst empty`, `worst blank`, `worst error`, `worst big`) and in `Probe.runWorst` (`Sidekick --probe out worst`). Rerun it after each fix; it saves a screenshot per case to `build/vm-out/`.

## Fixes

| # | Severity | What breaks | Value that breaks it | Fix | Where |
| --- | --- | --- | --- | --- | --- |
| 1 | Broken | An empty or whitespace-only answer shows nothing under the question, so it looks like nothing happened | `""`, `"   \n\n "` | When a done turn's answer is blank, show "No answer came back." in tertiary text | `Sources/SidekickApp/PanelView.swift`, `TurnView.status` |
| 2 | Ugly | A long question is cut at 8 lines with an ellipsis and cannot be read in full | a 600 character pasted question | Click the bubble to expand it (toggle the line limit, spring the height) | `PanelView.swift`, `TurnView` and `QuestionBubble` |
| 3 | Ugly | A wide table hides the columns past the card edge, with no sign that it scrolls | a 6 column table | A fade on the right edge while the table overflows | `Sources/SidekickApp/AnswerView.swift`, `TableBlock` |
| 4 | Ugly | A numbered list that starts at 1000 or more renders as a plain paragraph | `1284. The 1,284th member` | Allow up to 9 digits in the list marker (CommonMark) | `Sources/SidekickCore/Markdown.swift`, `listItem` |
| 5 | Gap | The history grabber needs hover and a drag, so keyboard and VoiceOver users cannot open history | n/a | ⌘↓ shows history, ⌘↑ hides it; add an accessibility action on the grabber | `PanelController.handleKey`, `PanelView.grabber` |
| 6 | Ugly | An unfinished `**bold**` shows its asterisks while the answer streams | a real stream that splits `**` across chunks | In the streaming tail only, hide an unclosed `**` or backtick until it closes | `Sources/SidekickCore/Markdown.swift`, `StreamingMarkdown` |
| 7 | Ugly, seen once | The field showed its first line half scrolled out for one frame when the text wrapped to a second line | typing a question that wraps, in dark appearance | Reproduce in the VM with frames at 60 fps first; then pin the field's scroll to the top while it grows | `PanelView.inputRow` |
| 8 | Fragile | The end of a 150 item list streams with a 114 ms main thread stall | `worst big` | Settle list items line by line in `StreamingMarkdown` so a long list is not reparsed whole | `Markdown.swift`, `StreamingMarkdown.settledEnd` |

## Decisions already suggested

- #2: click to expand, not always show the full question, so long pastes do not push the answer down.
- #3: a fade hint, not narrower wrapping columns, so number columns stay comparable.

## Done when

Each fixed row is checked again with the worst-case probe and its screenshot, `scripts/test.sh` passes, and the normal probe passes in the VM.
