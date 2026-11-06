import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Synapseless --render-docs <dir>`: draws the README images offscreen from demo data, frame by frame,
/// so no screen capture permission (and no real headset) is needed.
@MainActor
struct DocRenderer {
    let controller: HeadsetController
    let outDir: URL
    let fps = 25.0

    func run() {
        controller.applyDemoState()
        controller.lighting.sync(from: LightingState(effect: .wave, color: .razerGreen, color2: RGB(r: 0, g: 0.64, b: 1)))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        renderMenu()
        renderCard(.connected, file: "connect.gif", length: 3.6) { t, s, e in
            s.appear = t < 3.3 ? spring(t - 0.05, response: 0.55, damping: 0.78) : 1 - easeIn((t - 3.3) / 0.3)
            e.heroPop = spring(t - 0.17, response: 0.7, damping: 0.55)
            e.ringProgress = easeOut((t - 0.4) / 1.1)
        }
        renderCard(.disconnected(battery: 82, charging: false), file: "disconnect.gif", length: 3.8) { t, s, e in
            s.appear = t < 3.5 ? spring(t - 0.05, response: 0.55, damping: 0.78) : 1 - easeIn((t - 3.5) / 0.3)
            e.heroPop = spring(t - 0.17, response: 0.7, damping: 0.55)
            e.ringProgress = 1
            e.power = 1 - easeInOut((t - 0.75) / 1.2)
            e.lightsOut = t > 1.35
        }
        renderDeviceCard()
        print("Rendered README images to \(outDir.path)")
        exit(0)
    }

    // MARK: Scenes

    private func renderMenu() {
        controller.lighting.render(at: 1.2)
        let view = Backdrop {
            MenuView(controller: controller, lighting: controller.lighting, devices: StandardDeviceManager(), showCard: {})
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .padding(28)
        }
        let shot = Snapshotter(view)
        if let image = shot.capture() { writePNG(image, to: outDir.appendingPathComponent("menu.png")) }
        shot.close()
    }

    /// A catalog mouse, to show the card works for the experimental models too.
    static func demoMouse() -> CardSubject? {
        guard let model = RazerModel.byPID[0x00B6] else { return nil }
        let image = Bundle.main.url(forResource: "\(model.pid)_0", withExtension: "png", subdirectory: "devices")
            .flatMap(NSImage.init(contentsOf:))
        return CardSubject(key: "demo-mouse", title: model.name, label: "Ratón", showsBattery: true,
                           battery: 64, charging: false) { power, angle, size in
            AnyView(DeviceHero(image: image, symbol: "computermouse", size: size, power: power, angle: angle))
        }
    }

    /// Stills of a catalog mouse alone and of the combined headset + mouse card.
    private func renderDeviceCard() {
        guard let mouse = Self.demoMouse() else { return }
        for (file, subjects) in [("device-card.png", [mouse]), ("combined-card.png", [CardSubject.headset(controller), mouse])] {
            let state = PopupState()
            state.appear = 1
            state.entries = subjects.map { subject in
                let entry = CardEntry(subject: subject, kind: .connected)
                entry.heroPop = 1
                entry.ringProgress = 1
                return entry
            }
            controller.lighting.render(at: 1.2)
            let shot = Snapshotter(Backdrop { ConnectCard(state: state, haloAngle: 140, onClose: {}) })
            if let image = shot.capture() { writePNG(image, to: outDir.appendingPathComponent(file)) }
            shot.close()
        }
    }

    private func renderCard(_ kind: CardKind, file: String, length: Double,
                            step: (Double, PopupState, CardEntry) -> Void) {
        let state = PopupState()
        let entry = CardEntry(subject: .headset(controller), kind: kind)
        state.entries = [entry]
        let angle = AngleBox()
        let view = Backdrop {
            AngleReader(box: angle) { a in
                ConnectCard(state: state, haloAngle: a, onClose: {})
            }
        }
        let shot = Snapshotter(view)
        var frames: [CGImage] = []
        var t = 0.0
        while t <= length {
            step(t, state, entry)
            angle.value = 25 + t * 60
            controller.lighting.render(at: t)
            if let image = shot.capture() { frames.append(image) }
            t += 1 / fps
        }
        shot.close()
        writeGIF(frames, delay: 1 / fps, to: outDir.appendingPathComponent(file))
        // A still of the landed card for places that don't animate GIFs.
        if file == "connect.gif", frames.count > Int(2.5 * fps) {
            writePNG(frames[Int(2.5 * fps)], to: outDir.appendingPathComponent("card.png"))
        }
    }

    // MARK: Output

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                     kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, props) }
        CGImageDestinationFinalize(dest)
    }
}

// MARK: Timing curves (match the springs ConnectPopup animates with)

private func spring(_ t: Double, response: Double, damping: Double) -> Double {
    guard t > 0 else { return 0 }
    let w = 2 * .pi / response
    let wd = w * sqrt(1 - damping * damping)
    return 1 - exp(-damping * w * t) * (cos(wd * t) + (damping * w / wd) * sin(wd * t))
}
private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func easeOut(_ x: Double) -> Double { let c = clamp(x); return 1 - (1 - c) * (1 - c) * (1 - c) }
private func easeIn(_ x: Double) -> Double { let c = clamp(x); return c * c * c }
private func easeInOut(_ x: Double) -> Double { let c = clamp(x); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2 }

// MARK: Helpers

/// The halo angle as observable state, so each frame can set it.
private final class AngleBox: ObservableObject {
    @Published var value = 0.0
}

private struct AngleReader<Content: View>: View {
    @ObservedObject var box: AngleBox
    var content: (Double) -> Content
    var body: some View { content(box.value) }
}

/// A desktop-like gradient so the transparent card reads in a README.
private struct Backdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.renderingDocs, true)
            .background(
                LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.04, green: 0.16, blue: 0.09)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .environment(\.colorScheme, .dark)
    }
}

/// Hosts a view in an offscreen window and reads it back as a bitmap.
@MainActor
private final class Snapshotter {
    private let window: NSWindow
    private let hosting: NSView

    init<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.hosting = hosting
    }

    func capture() -> CGImage? {
        // Let SwiftUI apply the new state before drawing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    func close() { window.orderOut(nil) }
}

private struct RenderingDocsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while DocRenderer draws offscreen, where behind-window blur has nothing to blur.
    var renderingDocs: Bool {
        get { self[RenderingDocsKey.self] }
        set { self[RenderingDocsKey.self] = newValue }
    }
}
