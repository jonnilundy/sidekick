import AppKit
import SwiftUI
import SidekickCore

/// Claude's warm clay, used only for the spark and the cursor.
extension Color {
    static let sidekick = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// The whole window: a transparent area with the card hanging at the top right.
struct PanelView: View {
    @Bindable var model: PanelModel

    var body: some View {
        PanelCard(model: model)
            .frame(width: PanelMetrics.cardWidth)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { model.onCardSize?($0) }
            .offset(x: model.shown || model.reduceMotion ? 0 : PanelMetrics.cardWidth + PanelMetrics.edgeGap + 24)
            .scaleEffect(model.shown || model.reduceMotion ? 1 : 0.94, anchor: .trailing)
            .opacity(model.shown ? 1 : 0)
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

    private var conversation: Conversation { model.conversation }

    var body: some View {
        VStack(spacing: 0) {
            if !conversation.isEmpty {
                transcript
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider().opacity(0.5)
            }
            inputRow
        }
        .animation(.spring(response: Spring.grow.response, dampingFraction: Spring.grow.damping), value: conversation.isEmpty)
        .background { CardBackground() }
        .clipShape(.rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .onChange(of: model.focusRequest, initial: true) { focused = true }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, isLast: turn.id == conversation.turns.last?.id)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { transcriptHeight = $0 }
        }
        // Only when it really scrolls; otherwise a bar flashes while the card grows.
        .scrollIndicators(transcriptHeight > model.maxTranscriptHeight ? .automatic : .never)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(height: min(max(transcriptHeight, 1), model.maxTranscriptHeight))
        .animation(.spring(response: Spring.grow.response, dampingFraction: Spring.grow.damping), value: transcriptHeight)
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
                .onSubmit { model.submit() }
                .accessibilityIdentifier("sidekick-input")
            trailingButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
    }

    private var placeholder: String {
        if model.showWelcome { return "Ask anything. \(model.shortcutHint) opens me." }
        return conversation.isEmpty ? "Ask anything" : "Follow up"
    }

    @ViewBuilder private var trailingButton: some View {
        if conversation.isRunning {
            IconButton(symbol: "stop.fill", help: "Stop (⌘.)") { conversation.stop() }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if !conversation.isEmpty {
            IconButton(symbol: "arrow.counterclockwise", help: "Reset: start a fresh session (⌘N)") { model.onNew?() }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// One question and its answer.
struct TurnView: View {
    let turn: Conversation.Turn
    let isLast: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = turn.notice {
                Label(notice, systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }
            Text(turn.question)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(isLast ? 4 : 2)
                .textSelection(.enabled)

            if !turn.answer.isEmpty {
                AnswerView(markdown: turn.answer)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if hovering && !turn.answer.isEmpty && turn.status != .running {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy answer (⇧⌘C)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.answer, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.snappy) { copied = false } }
                }
                .offset(x: 6, y: -6)
                .transition(.opacity)
            }
        }
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
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Liquid Glass on macOS 26 and later, the popover material before that. Solid when the user asks for
/// less transparency.
struct CardBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26, *) {
            Rectangle().fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        } else {
            VisualEffect(material: .popover)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
