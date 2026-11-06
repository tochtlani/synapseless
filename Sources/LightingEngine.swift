import AppKit
import SwiftUI

struct RGB: Codable, Equatable {
    var r: Double, g: Double, b: Double

    static let razerGreen = RGB(r: 0.267, g: 0.839, b: 0.173)
    static let black = RGB(r: 0, g: 0, b: 0)

    static func hue(_ h: Double) -> RGB {
        let c = NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1, alpha: 1)
        return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    init(bytes: ArraySlice<UInt8>) {
        let b = Array(bytes) + [0, 0, 0]
        self.init(r: Double(b[0]) / 255, g: Double(b[1]) / 255, b: Double(b[2]) / 255)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    var bytes: [UInt8] {
        [r, g, b].map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }
}

/// Effects the headset firmware runs itself, set through property 0x40.
enum LightEffect: String, CaseIterable, Identifiable, Codable {
    case solid, breathing, breathingDual, breathingRandom, spectrum, wave, audioReactive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "Estático"
        case .breathing: "Respiración"
        case .breathingDual: "Respiración doble"
        case .breathingRandom: "Respiración aleatoria"
        case .spectrum: "Espectro"
        case .wave: "Ola"
        case .audioReactive: "Reactivo al audio"
        }
    }
    var colorCount: Int {
        switch self {
        case .solid, .breathing: 1
        case .breathingDual: 2
        default: 0
        }
    }
}

/// What the headset's lighting is set to, in the 0x40 encoding.
struct LightingState: Equatable {
    var effect: LightEffect
    var color: RGB
    var color2: RGB

    /// SET 0x40 payload.
    var payload: [UInt8] {
        switch effect {
        case .solid: [0x01] + color.bytes
        case .breathing: [0x02, 0x00] + color.bytes
        case .breathingDual: [0x02, 0x00] + color.bytes + color2.bytes
        case .breathingRandom: [0x02]
        case .spectrum: [0x03]
        // Synapse's "wheel" (0x0C); this firmware turns plain wave (0x04) into it anyway.
        case .wave: [0x0C]
        case .audioReactive: [0x0A]
        }
    }

    /// Parses a GET 0x40 reply; colours the headset doesn't report are kept from `fallback`.
    init?(reply p: [UInt8], fallback: LightingState) {
        guard let kind = p.first else { return nil }
        self = fallback
        switch kind {
        case 0x01 where p.count >= 4:
            effect = .solid; color = RGB(bytes: p[1...3])
        case 0x02 where p.count >= 8:
            effect = .breathingDual; color = RGB(bytes: p[2...4]); color2 = RGB(bytes: p[5...7])
        case 0x02 where p.count >= 5:
            effect = .breathing; color = RGB(bytes: p[2...4])
        case 0x00, 0x02:
            effect = .breathingRandom
        case 0x03:
            effect = .spectrum
        case 0x04, 0x0C:
            effect = .wave
        case 0x0A:
            effect = .audioReactive
        default:
            return nil
        }
    }

    init(effect: LightEffect, color: RGB, color2: RGB) {
        self.effect = effect; self.color = color; self.color2 = color2
    }
}

/// Live lamp colours for the on-screen headset, kept apart so 30 fps updates only redraw the previews.
final class LampPreview: ObservableObject {
    @Published var colors = [RGB](repeating: .razerGreen, count: BarracudaLink.lampCount)
}

/// Mirrors the headset's lighting and animates an approximation of it on screen.
/// The headset itself runs the effect; `onChange` pushes user edits to it.
final class LightingEngine: ObservableObject {
    @Published var effect: LightEffect = .wave { didSet { changed() } }
    @Published var color: RGB = .razerGreen { didSet { changed() } }
    @Published var color2: RGB = RGB(r: 0, g: 0.64, b: 1) { didSet { changed() } }

    let preview = LampPreview()
    var onChange: ((LightingState) -> Void)?

    var state: LightingState { LightingState(effect: effect, color: color, color2: color2) }

    private var syncing = false
    private var pushWork: DispatchWorkItem?
    private var timer: Timer?
    private let started = Date()

    init() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Takes the state read from the headset without echoing it back.
    func sync(from s: LightingState) {
        guard s != state else { return }
        syncing = true
        effect = s.effect; color = s.color; color2 = s.color2
        syncing = false
    }

    /// Colour pickers fire continuously; only send the value the user settles on.
    private func changed() {
        guard !syncing else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange?(self.state)
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func render() {
        render(at: Date().timeIntervalSince(started))
    }

    /// Sets the preview for time `t` seconds into the effect; DocRenderer calls it per frame.
    func render(at t: Double) {
        let n = BarracudaLink.lampCount
        let breath = 0.5 - 0.5 * cos(t * .pi * 2 / 4)
        switch effect {
        case .solid:
            preview.colors = Array(repeating: color, count: n)
        case .breathing:
            preview.colors = Array(repeating: color.scaled(0.15 + 0.85 * breath), count: n)
        case .breathingDual:
            let c = Int(t / 4) % 2 == 0 ? color : color2
            preview.colors = Array(repeating: c.scaled(0.15 + 0.85 * breath), count: n)
        case .breathingRandom:
            preview.colors = Array(repeating: RGB.hue(Double(Int(t / 4)) * 0.37).scaled(0.15 + 0.85 * breath), count: n)
        case .spectrum:
            preview.colors = Array(repeating: RGB.hue(t * 0.05), count: n)
        case .wave:
            preview.colors = (0..<n).map { RGB.hue(t * 0.15 + Double($0) / Double(n)) }
        case .audioReactive:
            // No audio level on our side; a beat-like pulse stands in for it.
            let beat = pow(max(0, sin(t * .pi * 2 * 1.1)), 6)
            preview.colors = (0..<n).map { RGB.hue(0.33 + Double($0) * 0.05).scaled(0.25 + 0.75 * beat) }
        }
    }
}
