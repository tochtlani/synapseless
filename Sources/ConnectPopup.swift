import AppKit
import SwiftUI

// MARK: Shared pieces

/// The headset glyph with a rotating Chroma halo fed by the live lamp colours.
struct HeadsetHero: View {
    @ObservedObject var preview: LampPreview
    var finish: HeadsetFinish
    var size: CGFloat
    /// 1 = lights on, 0 = powered off (halo gone, earcups dark). Animatable.
    var power: Double = 1
    /// Fixed halo angle for offscreen rendering (DocRenderer); nil follows the clock.
    var angle: Double?

    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = self.angle ?? timeline.date.timeIntervalSinceReferenceDate * 40
            let colors = preview.colors.map(\.color)
            let ring = colors + [colors.first ?? .green]
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: ring, center: .center))
                    .frame(width: size * 1.05, height: size * 1.05)
                    // Soft edge without relying on blur, which offscreen rendering drops.
                    .mask(RadialGradient(colors: [.white, .white.opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.53))
                    .blur(radius: size * 0.22)
                    .opacity(0.75 * power)
                    .scaleEffect(0.55 + 0.45 * power)
                    .rotationEffect(.degrees(angle))
                if let render = finish.image, let dimmed = finish.dimmedImage {
                    // The render has its earcup lights baked in; fading to a grey copy reads as "lights off".
                    ZStack {
                        Image(nsImage: dimmed).resizable().interpolation(.high).scaledToFit()
                        Image(nsImage: render).resizable().interpolation(.high).scaledToFit().opacity(power)
                    }
                    .frame(width: size * 1.15, height: size * 1.15)
                    .shadow(color: .white.opacity(0.18), radius: 1)
                    .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
                } else {
                    Image(systemName: "headphones")
                        .font(.system(size: size * 0.78, weight: .regular))
                        .foregroundStyle(
                            LinearGradient(colors: [finish.shades.0, finish.shades.1], startPoint: .top, endPoint: .bottom)
                        )
                        // A thin light rim keeps a black headset readable on the dark card.
                        .shadow(color: .white.opacity(finish == .black ? 0.35 : 0), radius: 0.8)
                        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
                        .opacity(0.55 + 0.45 * power)
                    // Earcup lights: left lamps 0–2, right lamps 3–5.
                    HStack(spacing: size * 0.56) {
                        earcup(Array(colors.prefix(3)))
                        earcup(Array(colors.suffix(3)))
                    }
                    .offset(y: size * 0.2)
                }
            }
            .frame(width: size * 1.3, height: size * 1.15)
        }
    }

    private func earcup(_ colors: [Color]) -> some View {
        Capsule()
            .fill(LinearGradient(colors: colors.isEmpty ? [.green] : colors, startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().fill(Color(white: 0.18)).opacity(1 - power))
            .frame(width: size * 0.09, height: size * 0.3)
            .shadow(color: (colors.first ?? .green).opacity(power), radius: size * 0.08)
    }
}

struct BatteryRing: View {
    var level: Int?
    var charging: Bool
    var progress: Double
    var diameter: CGFloat = 54
    var dimmed = false

    var body: some View {
        let value = Double(level ?? 0) / 100
        let tint: Color = dimmed ? .secondary
            : (level ?? 100) <= 20 && !charging ? .red : Color(red: 0.267, green: 0.839, blue: 0.173)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: value * progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if charging {
                Image(systemName: "bolt.fill").font(.system(size: diameter * 0.32, weight: .bold)).foregroundStyle(tint)
            } else {
                Text(level.map { "\($0)" } ?? "–").font(.system(size: diameter * 0.3, weight: .semibold, design: .rounded))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: Connection card

/// One device's slot in the card, with its own pop, battery fill and lights-out animation.
final class CardEntry: ObservableObject, Identifiable {
    let id = UUID()
    let subject: CardSubject
    let kind: CardKind
    @Published var heroPop = 0.0
    @Published var ringProgress = 0.0
    @Published var power = 1.0
    /// Flips the subtitle once the fade-out is half done (power itself jumps to 0 in the model).
    @Published var lightsOut = false

    init(subject: CardSubject, kind: CardKind) {
        self.subject = subject
        self.kind = kind
        if isDisconnect { ringProgress = 1 }
    }

    var isDisconnect: Bool {
        if case .disconnected = kind { return true }
        return false
    }
    var battery: Int? {
        if case let .disconnected(b, _) = kind { return b }
        return subject.battery
    }
    var charging: Bool {
        if case let .disconnected(_, c) = kind { return c }
        return subject.charging
    }
    var subtitle: String {
        if isDisconnect { return lightsOut ? "Desconectado" : "Apagando…" }
        return charging ? "Conectado · Cargando" : "Conectado"
    }
}

final class PopupState: ObservableObject {
    /// 0 = below the screen edge, 1 = landed. A number rather than a flag so DocRenderer can step it.
    @Published var appear = 0.0
    @Published var entries: [CardEntry] = []
}

enum CardKind {
    case connected
    /// Battery and charging as they were just before the link dropped.
    case disconnected(battery: Int?, charging: Bool)
}

/// What a card shows: the Barracuda (HeadsetController) or any catalog device (StandardDevice).
struct CardSubject {
    /// Identifies the device so a later event for it replaces its slot instead of adding one.
    var key: String
    var title: String
    /// Under the battery figure: "Audífonos", "Ratón"…
    var label: String
    var showsBattery: Bool
    var battery: Int?
    var charging: Bool
    /// Draws the device for a given power (1 lit, 0 off), optional fixed halo angle and size.
    var hero: (_ power: Double, _ angle: Double?, _ size: CGFloat) -> AnyView

    static func headset(_ controller: HeadsetController) -> CardSubject {
        CardSubject(key: "headset", title: BarracudaLink.displayName, label: "Audífonos", showsBattery: true,
                    battery: controller.battery, charging: controller.charging) { power, angle, size in
            AnyView(HeadsetHero(preview: controller.lighting.preview, finish: controller.finish, size: size,
                                power: power, angle: angle))
        }
    }

    static func kraken(_ device: KrakenDevice) -> CardSubject {
        CardSubject(key: "kraken", title: KrakenDevice.name, label: "Audífonos", showsBattery: false,
                    battery: nil, charging: false) { power, angle, size in
            AnyView(DeviceHero(image: nil, symbol: "headphones", size: size, power: power, angle: angle))
        }
    }

    static func device(_ device: StandardDevice) -> CardSubject {
        CardSubject(key: "pid-\(device.model.pid)", title: device.model.name, label: device.kindLabel,
                    showsBattery: device.model.hasBattery,
                    battery: device.battery, charging: device.charging) { power, angle, size in
            AnyView(DeviceHero(image: device.image, symbol: device.symbol, size: size, power: power, angle: angle))
        }
    }
}

/// One device: large when it has the card to itself, a compact column when sharing it, like the
/// AirPods card showing both buds and the case.
private struct EntryView: View {
    @ObservedObject var entry: CardEntry
    var compact: Bool
    var haloAngle: Double?

    private var heroSize: CGFloat { compact ? 78 : 110 }
    private var heroScale: Double { (0.6 + 0.4 * entry.heroPop) * (0.9 + 0.1 * entry.power) }
    private var charging: Bool { entry.charging && !entry.isDisconnect }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            entry.subject.hero(entry.power, haloAngle, heroSize)
                .scaleEffect(heroScale)
            titles
            if entry.subject.showsBattery { battery }
        }
        .frame(width: compact ? 150 : nil)
    }

    private var titles: some View {
        VStack(spacing: compact ? 4 : 8) {
            Text(entry.subject.title)
                .font(.system(size: compact ? 13 : 19, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.subtitle)
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    @ViewBuilder
    private var battery: some View {
        let ring = BatteryRing(level: entry.battery, charging: charging, progress: entry.ringProgress, diameter: compact ? 40 : 54,
                               dimmed: entry.isDisconnect)
        if compact {
            ring.padding(.top, 4)
        } else {
            HStack(spacing: 10) {
                ring
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.battery.map { "\($0) %" } ?? "–")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(entry.subject.label).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }
}

struct ConnectCard: View {
    @ObservedObject var state: PopupState
    var haloAngle: Double? = nil
    var onClose: () -> Void
    @Environment(\.renderingDocs) private var renderingDocs

    var body: some View {
        let compact = state.entries.count > 1
        VStack(spacing: 10) {
            HStack {
                if compact {
                    Text("\(state.entries.count) dispositivos")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(state.entries) { entry in
                    EntryView(entry: entry, compact: compact, haloAngle: haloAngle)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(width: compact ? nil : 340)
        .background {
            if renderingDocs { Color(white: 0.15).opacity(0.94) } else { VisualEffect() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(30)
        .offset(y: (1 - state.appear) * 420)
        .scaleEffect(0.9 + 0.1 * state.appear, anchor: .bottom)
        .opacity(min(1, state.appear * 1.5))
        .onTapGesture(perform: onClose)
    }
}

/// AirPods-style card that springs up from the bottom of the screen when a device links, and again,
/// with the lights fading out, when it powers off. Devices that arrive while it is up join the same
/// card side by side.
@MainActor
final class ConnectPopup {
    /// Wide enough for three compact columns; the transparent margin lets clicks through.
    private static let panelSize = NSSize(width: 640, height: 470)

    private var panel: NSPanel?
    private var state: PopupState?
    private var dismissWork: DispatchWorkItem?
    private var hiding = false

    func show(controller: HeadsetController, kind: CardKind = .connected) {
        show(.headset(controller), kind: kind)
    }

    func show(device: StandardDevice, kind: CardKind = .connected) {
        show(.device(device), kind: kind)
    }

    func show(_ subject: CardSubject, kind: CardKind = .connected) {
        let entry = CardEntry(subject: subject, kind: kind)
        if let state, panel != nil, !hiding {
            // Join the card that is already up; a new event for the same device replaces its slot.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                if let i = state.entries.firstIndex(where: { $0.subject.key == subject.key }) {
                    state.entries[i] = entry
                } else {
                    state.entries.append(entry)
                }
            }
            animateIn(entry, delay: 0.1)
        } else {
            present(entry)
        }
        scheduleHide(after: entry.isDisconnect ? 4 : 6)
    }

    private func present(_ entry: CardEntry) {
        teardown()
        let state = PopupState()
        state.entries = [entry]
        let card = ConnectCard(state: state) { [weak self] in self?.hide() }
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .bottom)
        let hosting = NSHostingView(rootView: card)
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.visibleFrame.midX - Self.panelSize.width / 2, y: screen.visibleFrame.minY)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        self.state = state

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { state.appear = 1 }
        }
        animateIn(entry, delay: 0.17)
    }

    /// The entry's own beats: the device pops, then the battery fills or the lights go out.
    private func animateIn(_ entry: CardEntry, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { entry.heroPop = 1 }
            if entry.isDisconnect {
                withAnimation(.easeInOut(duration: 1.2).delay(0.55)) { entry.power = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                    withAnimation(.easeInOut(duration: 0.25)) { entry.lightsOut = true }
                }
            } else {
                withAnimation(.easeOut(duration: 1.1).delay(0.2)) { entry.ringProgress = 1 }
            }
        }
    }

    private func scheduleHide(after seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        dismissWork?.cancel()
        guard let state, let panel else { return }
        hiding = true
        withAnimation(.easeIn(duration: 0.3)) { state.appear = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.panel === panel { self?.teardown() }
        }
    }

    private func teardown() {
        dismissWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        state = nil
        hiding = false
    }
}
