import ServiceManagement
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var controller: HeadsetController

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "headphones").opacity(controller.linked ? 1 : 0.45)
            if controller.linked, let b = controller.battery { Text("\(b)%") }
        }
    }
}

struct MenuView: View {
    @ObservedObject var controller: HeadsetController
    @ObservedObject var lighting: LightingEngine
    @ObservedObject var devices: StandardDeviceManager
    var showCard: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// nil shows the headset; otherwise the PID of a catalog device.
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !devices.devices.isEmpty {
                Picker("", selection: $selection) {
                    Text("Audífonos").tag(Int?.none)
                    ForEach(devices.devices) { d in
                        Text(d.model.name.replacingOccurrences(of: "Razer ", with: "")).tag(Int?.some(d.model.pid))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let pid = selection, let device = devices.devices.first(where: { $0.model.pid == pid }) {
                StandardDeviceView(device: device)
            } else {
                header
                if controller.linked {
                    Divider()
                    lightingSection
                    Divider()
                    eqSection
                    Divider()
                    micSection
                }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            HeadsetHero(preview: lighting.preview, finish: controller.finish, size: 44, power: controller.linked ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(BarracudaLink.displayName).font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.linked {
                BatteryRing(level: controller.battery, charging: controller.charging, progress: 1, diameter: 36)
            }
        }
    }

    private var status: String {
        if !controller.dongleConnected { return "Conecta el receptor USB" }
        if !controller.linked { return "Enciende los audífonos" }
        var s = controller.charging ? "Cargando" : "Conectado"
        if !controller.firmware.isEmpty { s += " · FW \(controller.firmware)" }
        return s
    }

    private var lightingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Iluminación Chroma", "light.max")
                Spacer()
                Toggle("Luces", isOn: Binding(get: { controller.lightsOn }, set: { controller.setLights($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if !controller.lightsOn {
                Text("Las luces están apagadas en el audífono.").font(.caption).foregroundStyle(.secondary)
            } else {
                lightingControls
            }
        }
    }

    private var lightingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Efecto", selection: $lighting.effect) {
                ForEach(LightEffect.allCases) { Text($0.title).tag($0) }
            }
            if lighting.effect.colorCount >= 1 {
                colorRow(lighting.effect.colorCount == 2 ? "Color 1" : "Color", $lighting.color)
            }
            if lighting.effect.colorCount == 2 {
                colorRow("Color 2", $lighting.color2)
            }
            HStack {
                Text("Brillo").frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { Double(controller.brightness) },
                                      set: { controller.brightness = Int($0.rounded()) }),
                       in: 1...255,
                       onEditingChanged: { if !$0 { controller.commitBrightness() } })
            }
        }
    }

    private func colorRow(_ title: String, _ selection: Binding<RGB>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(swatches, id: \.self) { hex in
                let c = RGB(hex: hex)
                Circle().fill(c.color).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white.opacity(selection.wrappedValue.bytes == c.bytes ? 0.9 : 0), lineWidth: 2))
                    .onTapGesture { selection.wrappedValue = c }
            }
            ColorPicker("", selection: Binding(get: { selection.wrappedValue.color }, set: { selection.wrappedValue = RGB($0) }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Ecualizador", "slider.vertical.3")
            Picker("", selection: Binding(get: { controller.eqPreset }, set: { controller.setEQPreset($0) })) {
                ForEach(EQPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let custom = controller.eqPreset == .custom
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        let value = custom ? controller.eqBands[i] : (controller.eqPreset.curve?[i] ?? 0)
                        Text(value > 0 ? "+\(value)" : "\(value)")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(value) },
                                              set: { controller.eqBands[i] = Int($0.rounded()) }),
                               in: Double(EQPreset.range.lowerBound)...Double(EQPreset.range.upperBound),
                               onEditingChanged: { editing in if !editing { controller.commitEQBands() } })
                            .controlSize(.mini)
                            .frame(width: 96)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 30, height: 96)
                            .disabled(!custom)
                        Text(EQPreset.bands[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if !custom {
                Text("Elige «Propio» para mover las bandas.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Micrófono y energía", "mic")
            Toggle("Escucharte a ti mismo (sidetone)",
                   isOn: Binding(get: { controller.sidetoneOn }, set: { controller.setSidetone($0) }))
            if controller.sidetoneOn {
                HStack {
                    Text("Nivel").frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { Double(controller.sidetoneLevel) },
                                          set: { controller.sidetoneLevel = Int($0.rounded()) }),
                           in: 0...15, step: 1,
                           onEditingChanged: { if !$0 { controller.commitSidetoneLevel() } })
                    Text("\(controller.sidetoneLevel)").monospacedDigit().frame(width: 22)
                }
            }
            Picker("Apagado automático",
                   selection: Binding(get: { controller.powerSave }, set: { controller.setPowerSave($0) })) {
                ForEach(powerOptions(including: controller.powerSave), id: \.self) { m in
                    Text(m == 0 ? "Nunca" : "\(m) min").tag(m)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir al iniciar sesión", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            if controller.linked {
                Button("Tarjeta", action: showCard).controlSize(.small)
            }
            Button("Salir") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }

    // MARK: Helpers

    private let swatches = ["44D62C", "FF0033", "00A2FF", "B000FF", "FF8A00", "FFFFFF"]

    private func powerOptions(including current: Int) -> [Int] {
        Array(Set([0, 5, 10, 15, 30, 60, current])).sorted()
    }

    private func sectionTitle(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Synapseless login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

extension RGB {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
}
