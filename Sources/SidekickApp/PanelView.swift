import AppKit
import SwiftUI
import SidekickCore

/// Claude's warm clay, used only for the spark and the cursor.
extension Color {
    static let sidekick = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Every motion value in the panel. Spring values for the slide live in SidekickCore's `Spring` so
/// checks can test them; this turns them into SwiftUI animations.
enum PanelMotion {
    /// The hotkey slide in from the screen edge.
    static let arrive = Animation.spring(response: Spring.arrive.response, dampingFraction: Spring.arrive.damping)
    /// The slide back out.
    static let leave = Animation.spring(response: Spring.leave.response, dampingFraction: Spring.leave.damping)
    /// A sent question rises out of the field into its place.
    static var rise: AnyTransition { AnyTransition.asymmetric(
        insertion: .offset(y: 36).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)).combined(with: .opacity),
        removal: .opacity) }
    /// Width, height and content changing together: a send, compact to full.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Transcript height changes.
    static let grow = Animation.spring(response: Spring.grow.response, dampingFraction: Spring.grow.damping)
    /// Pull release after a flick, and after a slow release.
    static let pullFlick = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let pullSettle = Animation.spring(response: 0.38, dampingFraction: 1)
    /// Button press feedback.
    static let press = Animation.spring(response: 0.16, dampingFraction: 1)
    /// A details section opening or closing.
    static let disclose = Animation.spring(response: 0.3, dampingFraction: 1)
    /// Reduced motion: fades instead of slides.
    static let fadeIn = Animation.easeOut(duration: 0.18)
    static let fadeOut = Animation.easeOut(duration: 0.14)
}

/// The whole window: a transparent area with the card hanging at the top right.
struct PanelView: View {
    @Bindable var model: PanelModel

    var body: some View {
        PanelCard(model: model)
            .frame(width: model.isCompact ? PanelMetrics.compactWidth : PanelMetrics.cardWidth)
            .animation(model.reduceMotion ? nil : PanelMotion.unfold, value: model.isCompact)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.onCardFrame?($0) }
            // On and off the screen edge by sliding only: the window ends at the edge and clips the card.
            // Reduced motion swaps the slide for a short fade.
            .offset(x: model.shown || model.reduceMotion ? 0 : PanelMetrics.cardWidth + PanelMetrics.edgeGap + 40)
            .opacity(model.reduceMotion && !model.shown ? 0 : 1)
            .padding(.top, PanelMetrics.top)
            .padding(.trailing, PanelMetrics.edgeGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The card: past turns on top, the text field at the bottom.
struct PanelCard: View {
    @Bindable var model: PanelModel
    @FocusState private var focused: Bool
    @State private var transcriptHeight: CGFloat = 0
    /// The live pull on the grabber, in points (down is positive), before rubber banding.
    @State private var pull: CGFloat = 0
    @State private var grabberHover = false

    private var conversation: Conversation { model.conversation }
    private var showsTranscript: Bool { !model.visibleTurns.isEmpty }
    private var stretch: CGFloat { CGFloat(HistoryDrag.rubberband(Double(pull))) }

    var body: some View {
        VStack(spacing: 0) {
            // Always in the tree: its height springs from 0, so the card unfolds instead of jumping.
            transcript
                .opacity(showsTranscript ? 1 : 0)
            Divider().opacity(showsTranscript ? 0.5 : 0).frame(height: showsTranscript ? nil : 0)
            inputRow
            // Pulling down stretches the card under the finger before the history opens.
            Color.clear.frame(height: max(0, stretch))
        }
        .overlay(alignment: .bottom) { grabber }
        .background { CardBackground() }
        .clipShape(.rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .onChange(of: model.focusRequest, initial: true) { focused = true }
    }

    // MARK: Transcript

    private func isJustSent(_ turn: Conversation.Turn) -> Bool {
        turn.id == conversation.turns.last?.id && turn.status == .running
    }

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

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(model.visibleTurns) { turn in
                    TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id)
                        // Only the question just sent rises; turns revealed by the pull fade in where they are.
                        .transition(model.reduceMotion ? .opacity : (isJustSent(turn) ? PanelMotion.rise : .opacity))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { setTranscriptHeight($0) }
        }
        // Only when it really scrolls; otherwise a bar flashes while the card grows.
        .scrollIndicators(transcriptHeight > model.maxTranscriptHeight ? .automatic : .never)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Pushing up on an open history shrinks it under the finger before it tucks away.
        .frame(height: showsTranscript ? max(1, min(max(transcriptHeight, 1), model.maxTranscriptHeight) + min(0, stretch)) : 0)
        .clipped()
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Spark(running: conversation.isRunning)
            TextField(placeholder, text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .tint(.sidekick)
                .onSubmit { withAnimation(model.reduceMotion ? PanelMotion.fadeIn : PanelMotion.unfold) { model.submit() } }
                .accessibilityIdentifier("sidekick-input")
            trailingButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
        // The row always lays out at full width and the card's edge clips it while compact, so the text
        // never wraps at the narrow width and keeps that wrap after the card widens.
        .frame(width: PanelMetrics.cardWidth, alignment: .leading)
        // Both bounds: this frame takes the card's width, not the row's, so the row cannot push the card wider.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: String {
        if model.showWelcome { return "Ask anything. \(model.shortcutHint) opens me." }
        return showsTranscript ? "Follow up" : "Ask anything"
    }

    // MARK: Grabber

    /// A small handle on the bottom edge: pull down for earlier questions, push up to tuck them away.
    @ViewBuilder private var grabber: some View {
        if model.canPull {
            // Hidden until the pointer is on the bottom edge, so the card stays clean.
            Capsule()
                .fill(.primary.opacity(grabberHover || pull != 0 ? 0.32 : 0))
                .frame(width: pull != 0 ? 40 : 32, height: 4)
                .frame(width: 180, height: 16)
                .contentShape(Rectangle())
                .offset(y: -1)
                .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { grabberHover = inside } }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in pull = value.translation.height }
                        .onEnded { value in finishPull(translation: value.translation.height, velocity: value.velocity.height) }
                )
                .onTapGesture { finishPull(translation: model.historyOpen ? -100 : 100, velocity: 0) }
                .help(model.historyOpen ? "Push up to hide earlier questions" : "Pull down for earlier questions")
                .accessibilityLabel(model.historyOpen ? "Hide earlier questions" : "Show earlier questions")
                .accessibilityAddTraits(.isButton)
                .transition(.opacity)
        }
    }

    private func finishPull(translation: CGFloat, velocity: CGFloat) {
        let outcome = HistoryDrag.outcome(translation: Double(translation), velocity: Double(velocity), isOpen: model.historyOpen)
        // A flick hands its speed to the spring, a slow release settles calmly.
        let animation: Animation = model.reduceMotion ? PanelMotion.fadeIn : (abs(velocity) > 300 ? PanelMotion.pullFlick : PanelMotion.pullSettle)
        withAnimation(animation) {
            switch outcome {
            case .open: model.showHistory()
            case .close: model.hideHistory()
            case .stay: break
            }
            pull = 0
        }
        model.touch()
        model.focusRequest += 1
    }

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
}

/// One question and its answer. The question sits in a tinted bubble on the right, like a sent message.
struct TurnView: View {
    let turn: Conversation.Turn
    let isLast: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = turn.notice {
                Label(notice, systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(isLast ? 8 : 3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.sidekick.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.sidekick.opacity(0.22), lineWidth: 0.5))
            }

            if !turn.answer.isEmpty {
                AnswerView(markdown: turn.answer, streaming: turn.status == .running)
                    .overlay(alignment: .bottomTrailing) {
                        if hovering && turn.status != .running {
                            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy answer (⇧⌘C)") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(turn.answer, forType: .string)
                                withAnimation(.snappy) { copied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.snappy) { copied = false } }
                            }
                            .background(Circle().fill(Color.sidekickCard))
                            .offset(x: 6, y: 6)
                            .transition(.opacity)
                        }
                    }
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }

    @ViewBuilder private var status: some View {
        switch turn.status {
        case .running:
            if turn.answer.isEmpty || turn.activity != nil {
                Thinking(label: turn.activity ?? "Thinking")
            }
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        case .failed(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        case .done:
            EmptyView()
        }
    }
}

/// A shimmering status line while claude works ("Thinking", "Searching the web: …").
struct Thinking: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(label)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
                        GeometryReader { proxy in
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: proxy.size.width * 0.5)
                                .offset(x: (phase * 1.5 - 0.5) * proxy.size.width)
                        }
                        .blendMode(.plusLighter)
                    }
                    .mask(Text(label).font(.system(size: 13)).lineLimit(1).truncationMode(.middle))
                    .allowsHitTesting(false)
                }
            }
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: label)
            .accessibilityLabel(label)
    }
}

/// The spark at the start of the text field. It breathes while an answer is coming.
struct Spark: View {
    let running: Bool

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.sidekick)
            .symbolEffect(.pulse, options: .repeating, isActive: running)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

/// A small round button that highlights on press.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(PanelMotion.press, value: configuration.isPressed)
    }
}

/// Solid black in dark mode, solid white in light mode. No translucency.
struct CardBackground: View {
    var body: some View {
        Rectangle().fill(Color.sidekickCard)
    }
}

extension Color {
    /// The card: pure black or pure white, following the system appearance.
    static let sidekickCard = Color(nsColor: NSColor(name: "sidekickCard") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
}
