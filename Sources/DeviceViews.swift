import AppKit
import SwiftUI

extension StandardDevice {
    var kindLabel: String {
        switch model.kind {
        case .mouse: "Ratón"
        case .keyboard: "Teclado"
        case .laptop: "Laptop"
        case .mousepad: "Mousepad"
        case .accessory: "Accesorio"
        }
    }
}

/// Card / menu art for catalog devices: the Synapse render when there is one, else an SF Symbol,
/// over the same rotating Chroma halo as the headset.
struct DeviceHero: View {
    var image: NSImage?
    var symbol: String
    var size: CGFloat
    var power: Double = 1
    var angle: Double?

    private let chroma: [Color] = [.green, .cyan, .blue, .purple, .pink, .orange, .yellow, .green]

    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = self.angle ?? timeline.date.timeIntervalSinceReferenceDate * 40
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: chroma, center: .center))
                    .frame(width: size * 1.05, height: size * 1.05)
                    .mask(RadialGradient(colors: [.white, .white.opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.53))
                    .blur(radius: size * 0.22)
                    .opacity(0.7 * power)
                    .scaleEffect(0.55 + 0.45 * power)
                    .rotationEffect(.degrees(angle))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size * 1.1, height: size * 1.1)
                        .opacity(0.55 + 0.45 * power)
                        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.6, weight: .regular))
                        .foregroundStyle(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)],
                                                        startPoint: .top, endPoint: .bottom))
                        .opacity(0.55 + 0.45 * power)
                }
            }
            .frame(width: size * 1.3, height: size * 1.15)
        }
    }
}

/// Menu section for one catalog device. Every control here is untested on real hardware.
struct StandardDeviceView: View {
    @ObservedObject var device: StandardDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text("Experimental: este modelo no se ha probado. Si algo no responde, avísanos.")
                .font(.caption2)
                .foregroundStyle(.orange)
            Divider()
            lighting
            if let range = device.model.dpi {
                Divider()
                sensor(range)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DeviceHero(image: device.image, symbol: device.symbol, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.model.name).font(.headline).lineLimit(2)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.model.hasBattery {
                BatteryRing(level: device.battery, charging: device.charging, progress: 1, diameter: 36)
            }
        }
    }

    private var status: String {
        var s = "\(device.kindLabel) · USB \(String(format: "%04X", device.model.pid))"
        if !device.firmware.isEmpty { s += " · FW \(device.firmware)" }
        return s
    }

    private var lighting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Iluminación Chroma", systemImage: "light.max").font(.subheadline.weight(.semibold))
            Picker("Efecto", selection: Binding(get: { device.effect }, set: { device.effect = $0; device.applyEffect() })) {
                ForEach(StandardEffect.allCases) { Text($0.title).tag($0) }
            }
            if device.effect.usesColor {
                HStack {
                    Text("Color")
                    Spacer()
                    ColorPicker("", selection: Binding(get: { device.color.color },
                                                       set: { device.color = RGB($0) }),
                                supportsOpacity: false)
                        .labelsHidden()
                    Button("Aplicar") { device.applyEffect() }.controlSize(.small)
                }
            }
            HStack {
                Text("Brillo").frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { Double(device.brightness) }, set: { device.brightness = Int($0.rounded()) }),
                       in: 0...255,
                       onEditingChanged: { if !$0 { device.commitBrightness() } })
            }
        }
    }

    private func sensor(_ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sensor", systemImage: "scope").font(.subheadline.weight(.semibold))
            HStack {
                Text("DPI").frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { Double(device.dpi) },
                                      set: { device.dpi = Int(($0 / Double(device.model.dpiStep)).rounded()) * device.model.dpiStep }),
                       in: Double(range.lowerBound)...Double(range.upperBound),
                       onEditingChanged: { if !$0 { device.commitDPI() } })
                Text("\(device.dpi)").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            if !device.model.hyperPolling {
                Picker("Polling", selection: Binding(get: { device.polling ?? 1000 }, set: { device.setPolling($0) })) {
                    ForEach([125, 500, 1000], id: \.self) { Text("\($0) Hz").tag($0) }
                }
            }
        }
    }
}
