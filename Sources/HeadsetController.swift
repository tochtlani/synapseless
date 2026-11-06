import AppKit
import CoreImage
import IOKit.hid
import SwiftUI

enum EQPreset: UInt8, CaseIterable, Identifiable {
    case game = 0x07, movie = 0x09, music = 0x08, custom = 0xFF
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .game: "Juego"
        case .movie: "Película"
        case .music: "Música"
        case .custom: "Propio"
        }
    }
    /// Firmware curves (dB) for the built-in presets, shown read-only in the UI.
    var curve: [Int]? {
        switch self {
        case .game: [-4, -3, -2, -1, 0, 1, 2, 2, 2, 1]
        case .movie: [5, 4, 3, 1, -2, 1, 2, 3, 3, 2]
        case .music: [2, 2, 1, 0, -1, 1, 2, 3, 2, 2]
        case .custom: nil
        }
    }
    static let bands = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range = -12...12
}

/// Edition ID from property 0x01 ("Get Edition ID" in Synapse); the IDs match Synapse's renders.
enum HeadsetFinish: UInt8 {
    case black = 0, white = 128, greenClear = 129, blackClear = 130, clear = 131

    var title: String {
        switch self {
        case .black: "Negro"
        case .white: "Blanco"
        case .greenClear: "Verde translúcido"
        case .blackClear: "Negro translúcido"
        case .clear: "Transparente"
        }
    }
    /// Product render bundled in Resources, used instead of the generic glyph when present.
    var image: NSImage? { Self.renders[self]?.lit }
    /// The same render desaturated and darkened, cross-faded in as the lights go out.
    var dimmedImage: NSImage? { Self.renders[self]?.dim }

    private static var renders: [HeadsetFinish: (lit: NSImage, dim: NSImage)] = {
        var out: [HeadsetFinish: (NSImage, NSImage)] = [:]
        for finish in [HeadsetFinish.black, .white, .greenClear, .blackClear, .clear] {
            guard let url = Bundle.main.url(forResource: "headset-\(finish.rawValue)", withExtension: "png"),
                  let lit = NSImage(contentsOf: url),
                  let ci = CIImage(contentsOf: url),
                  let filter = CIFilter(name: "CIColorControls") else { continue }
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(0.1, forKey: kCIInputSaturationKey)
            filter.setValue(-0.08, forKey: kCIInputBrightnessKey)
            guard let output = filter.outputImage,
                  let cg = CIContext().createCGImage(output, from: ci.extent) else { continue }
            out[finish] = (lit, NSImage(cgImage: cg, size: lit.size))
        }
        return out
    }()
    /// Top and bottom of the fallback glyph gradient.
    var shades: (Color, Color) {
        switch self {
        case .white, .clear: (.white, Color(white: 0.80))
        case .greenClear: (Color(red: 0.3, green: 0.55, blue: 0.35), Color(red: 0.1, green: 0.3, blue: 0.15))
        case .black, .blackClear: (Color(white: 0.30), Color(white: 0.06))
        }
    }
}

/// Watches for the dongle, polls the headset link and mirrors its settings.
final class HeadsetController: ObservableObject {
    @Published private(set) var dongleConnected = false
    @Published private(set) var linked = false
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var eqPreset: EQPreset = .music
    @Published var eqBands = [Int](repeating: 0, count: 10)
    @Published private(set) var sidetoneOn = false
    @Published var sidetoneLevel = 7
    @Published private(set) var powerSave = 15
    @Published private(set) var firmware = ""
    @Published private(set) var finish: HeadsetFinish = .black
    /// 0–255 as the headset reports it; 0 means the lights are off.
    @Published var brightness = 128
    var lightsOn: Bool { brightness > 0 }

    let lighting = LightingEngine()
    var onHeadsetConnected: (() -> Void)?
    /// Called with the last battery reading and charging state before the link drops.
    var onHeadsetDisconnected: ((Int?, Bool) -> Void)?

    private(set) var link: BarracudaLink?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var pollTimer: Timer?
    private var ticks = 0
    private var lastBrightness = 128
    /// Polling must not overwrite a value the user is still adjusting.
    private var lastUserWrite = Date.distantPast

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: BarracudaLink.vendorID,
            kIOHIDProductIDKey: BarracudaLink.productID,
            kIOHIDPrimaryUsagePageKey: 0xFF13,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<HeadsetController>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<HeadsetController>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        lighting.onChange = { [weak self] state in self?.pushLighting(state) }
    }

    /// Fixed, plausible values for the README images (`--render-docs`); the device is never opened.
    func applyDemoState() {
        dongleConnected = true
        linked = true
        battery = 82
        charging = false
        eqPreset = .custom
        eqBands = [3, 2, 1, 0, -1, 0, 2, 3, 2, 1]
        sidetoneOn = true
        sidetoneLevel = 7
        powerSave = 15
        firmware = "1.0.9"
        finish = .black
        brightness = 200
    }

    // MARK: Connection

    private func attach(_ device: IOHIDDevice) {
        guard link == nil, let newLink = BarracudaLink(device) else { return }
        link = newLink
        dongleConnected = true
        poll()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let current = link, current.hid == device else { return }
        current.close()
        link = nil
        dongleConnected = false
        if linked { onHeadsetDisconnected?(battery, charging) }
        markUnlinked()
    }

    private func markUnlinked() {
        linked = false
        battery = nil
        charging = false
    }

    private func poll() {
        guard let link else { return }
        ticks += 1
        // Ask the dongle: a powered-off headset doesn't answer at all.
        link.get(.linked, from: .dongle) { [weak self] payload in
            guard let self, let payload else { return }
            let nowLinked = payload.first == 1
            if nowLinked && !self.linked {
                self.linked = true
                self.refreshAll { self.onHeadsetConnected?() }
            } else if !nowLinked && self.linked {
                self.onHeadsetDisconnected?(self.battery, self.charging)
                self.markUnlinked()
            } else if nowLinked {
                // Pick up changes made with the headset's own buttons.
                if self.ticks % 2 == 0 { self.syncFromHeadset() }
                if self.ticks % 15 == 0 { self.refreshBattery() }
            }
        }
    }

    func refreshBattery(done: (() -> Void)? = nil) {
        link?.get([.battery, .charging]) { [weak self] r in
            if let b = r[.battery]?.first { self?.battery = Int(b) }
            if let c = r[.charging]?.first { self?.charging = c == 1 }
            done?()
        }
    }

    func refreshAll(done: (() -> Void)? = nil) {
        link?.get([.battery, .charging, .eqPreset, .eqCurve, .sidetoneOn, .sidetoneLevel, .powerSave, .firmware, .edition, .lighting, .brightness]) { [weak self] r in
            guard let self else { return }
            if let b = r[.battery]?.first { self.battery = Int(b) }
            if let c = r[.charging]?.first { self.charging = c == 1 }
            if let p = r[.eqPreset]?.first, let preset = EQPreset(rawValue: p) { self.eqPreset = preset }
            if let curve = r[.eqCurve], curve.count == 10 { self.eqBands = curve.map { Int(Int8(bitPattern: $0)) } }
            if let s = r[.sidetoneOn]?.first { self.sidetoneOn = s != 0 }
            if let l = r[.sidetoneLevel]?.first { self.sidetoneLevel = Int(l) }
            if let m = r[.powerSave]?.first { self.powerSave = Int(m) }
            if let f = r[.firmware], f.count >= 3 { self.firmware = f.prefix(3).map(String.init).joined(separator: ".") }
            if let e = r[.edition]?.first { self.finish = HeadsetFinish(rawValue: e) ?? .black }
            self.applyLighting(r)
            done?()
        }
    }

    private func syncFromHeadset() {
        guard Date().timeIntervalSince(lastUserWrite) > 3 else { return }
        link?.get([.eqPreset, .lighting, .brightness]) { [weak self] r in
            guard let self, Date().timeIntervalSince(self.lastUserWrite) > 3 else { return }
            self.applyLighting(r)
            if let p = r[.eqPreset]?.first, let preset = EQPreset(rawValue: p), preset != self.eqPreset {
                self.eqPreset = preset
                if preset == .custom {
                    self.link?.get(.eqCurve) { c in
                        if let c, c.count == 10 { self.eqBands = c.map { Int(Int8(bitPattern: $0)) } }
                    }
                }
            }
        }
    }

    private func applyLighting(_ r: [BarracudaLink.Prop: [UInt8]]) {
        if let p = r[.lighting], let state = LightingState(reply: p, fallback: lighting.state) { lighting.sync(from: state) }
        if let b = r[.brightness]?.first {
            brightness = Int(b)
            if b > 0 { lastBrightness = Int(b) }
        }
    }

    // MARK: Lighting

    private func pushLighting(_ state: LightingState) {
        lastUserWrite = Date()
        link?.set(.lighting, state.payload)
        if !lightsOn { setLights(true) }
    }

    func setLights(_ on: Bool) {
        brightness = on ? max(lastBrightness, 16) : 0
        commitBrightness()
    }

    func commitBrightness() {
        lastUserWrite = Date()
        if brightness > 0 { lastBrightness = brightness }
        link?.set(.brightness, [UInt8(min(max(brightness, 0), 255))])
        link?.get(.brightness) { [weak self] p in if let v = p?.first { self?.brightness = Int(v) } }
    }

    // MARK: Settings (each write is confirmed by reading the value back)

    func setEQPreset(_ preset: EQPreset) {
        guard let link else { return }
        lastUserWrite = Date()
        link.set(.eqPreset, [preset.rawValue])
        if preset == .custom { link.set(.eqCurve, eqBands.map { UInt8(bitPattern: Int8($0)) }) }
        link.get(.eqPreset) { [weak self] p in
            if let v = p?.first, let read = EQPreset(rawValue: v) { self?.eqPreset = read }
        }
    }

    func commitEQBands() {
        guard let link else { return }
        lastUserWrite = Date()
        let bands = eqBands.map { min(max($0, EQPreset.range.lowerBound), EQPreset.range.upperBound) }
        if eqPreset != .custom { link.set(.eqPreset, [EQPreset.custom.rawValue]) }
        link.set(.eqCurve, bands.map { UInt8(bitPattern: Int8($0)) })
        link.get([.eqPreset, .eqCurve]) { [weak self] r in
            guard let self else { return }
            if let v = r[.eqPreset]?.first, let read = EQPreset(rawValue: v) { self.eqPreset = read }
            if let curve = r[.eqCurve], curve.count == 10 { self.eqBands = curve.map { Int(Int8(bitPattern: $0)) } }
        }
    }

    func setSidetone(_ on: Bool) {
        link?.set(.sidetoneOn, [on ? 1 : 0])
        link?.get(.sidetoneOn) { [weak self] p in if let v = p?.first { self?.sidetoneOn = v != 0 } }
    }

    func commitSidetoneLevel() {
        link?.set(.sidetoneLevel, [UInt8(min(max(sidetoneLevel, 0), 15))])
        link?.get(.sidetoneLevel) { [weak self] p in if let v = p?.first { self?.sidetoneLevel = Int(v) } }
    }

    func setPowerSave(_ minutes: Int) {
        link?.set(.powerSave, [UInt8(minutes)])
        link?.get(.powerSave) { [weak self] p in if let v = p?.first { self?.powerSave = Int(v) } }
    }
}
