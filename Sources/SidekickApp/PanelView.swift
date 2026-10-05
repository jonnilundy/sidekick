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
    /// Where the typed text sits in the field, in card coordinates. The flight starts here.
    @State private var fieldTextFrame: CGRect = .zero
    /// The question in flight from the field to its bubble.
    @State private var flight: SendFlight?
    /// The sent text, held in the field for the first moments of the flight.
    @State private var heldText: String?

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
        // Above the transcript's clip, so the question is visible all the way from the field.
        .overlay(alignment: .topLeading) { flightView }
        .coordinateSpace(.named(SendFlight.space))
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

    // MARK: Send

    /// Sends, and lifts the typed text out of the field into its bubble while the card expands around
    /// it, so the card reads as one surface growing to fit, not a new view replacing the old one.
    private func send() {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = fieldTextFrame
        let before = conversation.turns.last?.id
        if !model.reduceMotion, !text.isEmpty, !conversation.isRunning {
            heldText = text
            // The flight takes about 0.15 s to show on screen; hand over just as it does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeOut(duration: 0.06)) { heldText = nil }
            }
        }
        withAnimation(model.reduceMotion ? PanelMotion.fadeIn : PanelMotion.unfold) { model.submit() }
        guard !model.reduceMotion, !text.isEmpty, from.width > 0,
              let sent = conversation.turns.last, sent.id != before, sent.question == text else { return }
        flight = SendFlight(turnID: sent.id, text: text, from: from)
        SendFlight.debug("send from \(from) for \(text)")
        // If the bubble never reports a frame (it scrolled out of view), give up and show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if flight?.turnID == sent.id { flight = nil } }
    }

    /// The new bubble has its place: fly to it on the same spring the card expands with.
    private func bubbleLanded(_ turnID: Int, at frame: CGRect) {
        guard var current = flight, current.turnID == turnID, frame.width > 0 else { return }
        // The bubble moves every frame while the card widens and grows around it. Track it as is, with no
        // animation of its own: the flight's progress is what animates, so it always lands on the bubble.
        let first = current.to == nil
        if first { SendFlight.debug("first bubble frame \(frame)") }
        current.to = frame
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) { flight = current }
        guard first else { return }
        DispatchQueue.main.async {
            withAnimation(PanelMotion.unfold) {
                flight?.progress = 1
            } completion: {
                if flight?.turnID == turnID { flight = nil }
            }
        }
    }

    /// The question in flight: the field's text at first, the bubble when it lands.
    @ViewBuilder private var flightView: some View {
        if let flight, let to = flight.to {
            // The bubble's own size, measured from its text, so a half-done layout can never squeeze it.
            let size = SendFlight.bubbleSize(flight.text)
            let startScale = SendFlight.fieldFontSize / SendFlight.bubbleFontSize
            // At the start the bubble's text lines up with the field's text: leading edges and centers match.
            let start = CGPoint(x: flight.from.minX - SendFlight.bubblePadding * startScale + size.width * startScale / 2, y: flight.from.midY)
            // At the end it sits where the real bubble is now: right edges and centers match.
            let end = CGPoint(x: to.maxX - size.width / 2, y: to.midY)
            FlyingQuestion(text: flight.text, size: size, progress: flight.progress, start: start, end: end, startScale: startScale)
                .allowsHitTesting(false)
                // Inserted inside the send's animation, the default fade would hide the text for the
                // first part of the flight. It must be there from the first frame.
                .transition(.identity)
        } else if let flight {
            // One frame before the bubble has a place: hold the text where it was typed.
            Text(flight.text)
                .font(.system(size: SendFlight.fieldFontSize))
                .lineLimit(6)
                .frame(width: flight.from.width, height: flight.from.height, alignment: .topLeading)
                .position(x: flight.from.midX, y: flight.from.midY)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }

    /// Streaming growth lands at once: animating every batch would lay the transcript out each frame.
    /// Sends, collapses and reveals still spring, including the first growth after a send (the answer is
    /// still empty then), so the card expands from the field instead of snapping open.
    private func setTranscriptHeight(_ height: CGFloat) {
        let growth = height - transcriptHeight
        let streamingText = conversation.isRunning && conversation.turns.last?.answer.isEmpty == false
        if model.reduceMotion || (streamingText && growth > 0 && growth < 80) {
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
                    TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id,
                             hidesQuestion: flight?.turnID == turn.id,
                             onBubbleFrame: { frame in bubbleLanded(turn.id, at: frame) })
                        // The question just sent arrives by the flight (or rises, when there is no flight);
                        // turns revealed by the pull fade in where they are.
                        .transition(model.reduceMotion || flight?.turnID == turn.id || !isJustSent(turn) ? .opacity : PanelMotion.rise)
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
                .onSubmit { send() }
                .accessibilityIdentifier("sidekick-input")
                // A copy of the typed text. Invisible while typing, it only measures where the text sits.
                // Right after a send it shows the sent text in place, so the words never blink out
                // before the flight has picked them up.
                .background(alignment: .topLeading) {
                    Text(heldText ?? (model.input.isEmpty ? " " : model.input))
                        .font(.system(size: 15))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(heldText == nil ? 0 : 1)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SendFlight.space)) }) { fieldTextFrame = $0 }
                }
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
        if heldText != nil { return "" }
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

/// A question on its way from the field to its bubble.
struct SendFlight: Equatable {
    static let space = "sidekick-card"
    static let fieldFontSize: CGFloat = 15
    static let bubbleFontSize: CGFloat = 13.5
    static let bubblePadding: CGFloat = 12

    let turnID: Int
    let text: String
    /// The typed text's frame in the field, in card coordinates.
    let from: CGRect
    /// The bubble's frame once laid out.
    var to: CGRect?
    /// 0 in the field, 1 in the bubble. The only animated value of the flight.
    var progress: Double = 0

    static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["SIDEKICK_DEBUG"] != nil else { return }
        print(String(format: "flight %.3f: ", ProcessInfo.processInfo.systemUptime) + message)
    }

    /// The widest a bubble gets: the transcript's width less its 48 pt leading spacer.
    static let maxBubbleWidth: CGFloat = PanelMetrics.cardWidth - 36 - 48

    /// The size `QuestionBubble` takes for this text: the text in the bubble's font, wrapped at the widest
    /// a bubble gets, at most 8 lines, plus the bubble's padding.
    static func bubbleSize(_ text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: bubbleFontSize, weight: .medium)
        let maxText = maxBubbleWidth - bubblePadding * 2
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(ceil(bounds.height), lineHeight * 8)
        return CGSize(width: min(ceil(bounds.width) + bubblePadding * 2 + 1, maxBubbleWidth), height: height + 14)
    }
}

/// Places the flying question between the field (progress 0) and its bubble (progress 1). Only progress
/// animates; `end` follows the bubble as the card moves, so the flight lands exactly on it.
struct FlyingQuestion: View, Animatable {
    let text: String
    let size: CGSize
    var progress: Double
    let start: CGPoint
    let end: CGPoint
    let startScale: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = CGFloat(progress)
        // The tint grows in as the text leaves the field and becomes a bubble.
        QuestionBubble(text: text, lineLimit: 8, fill: min(1, progress * 1.6))
            .frame(width: size.width, height: size.height)
            .scaleEffect(startScale + (1 - startScale) * p)
            .position(x: start.x + (end.x - start.x) * p, y: start.y + (end.y - start.y) * p)
    }
}

/// The tinted bubble a question sits in. `fill` fades the bubble's tint in while the text flies.
struct QuestionBubble: View {
    let text: String
    let lineLimit: Int
    var fill: Double = 1

    var body: some View {
        Text(text)
            .font(.system(size: SendFlight.bubbleFontSize, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            .padding(.horizontal, SendFlight.bubblePadding)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.sidekick.opacity(0.16 * fill)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.sidekick.opacity(0.22 * fill), lineWidth: 0.5))
    }
}

/// One question and its answer. The question sits in a tinted bubble on the right, like a sent message.
struct TurnView: View {
    let turn: Conversation.Turn
    let isLast: Bool
    /// True while this question is still flying in from the field; the flight draws it meanwhile.
    var hidesQuestion = false
    var onBubbleFrame: (CGRect) -> Void = { _ in }
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
                QuestionBubble(text: turn.question, lineLimit: isLast ? 8 : 3)
                    .textSelection(.enabled)
                    .opacity(hidesQuestion ? 0 : 1)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SendFlight.space)) }) { onBubbleFrame($0) }
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
