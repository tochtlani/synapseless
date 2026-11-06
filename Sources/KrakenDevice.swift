import AppKit
import IOKit.hid
import SwiftUI

/// Razer Kraken Ultimate (1532:0527), wired USB. Memory-style protocol, from openrazer's
/// razerkraken_driver and verified on real hardware (firmware 2.50):
///
///   output report 0x04, 37 bytes: 04 <dest> <len> <addrHi> <addrLo> <32 bytes of data>
///   input report 0x05: 05 <data…>; it doesn't echo the address, so reads go one at a time.
///
/// Everything here runs on the main thread (the device is scheduled on the main run loop).
final class KrakenLink {
    static let vendorID = 0x1532
    static let productID = 0x0527

    private enum Destination: UInt8 { case readRAM = 0x00, readEEPROM = 0x20, writeRAM = 0x40 }

    /// Only RAM is ever written, so nothing here outlives a power cycle.
    enum RAM {
        /// One byte, bitfield: see KrakenEffect.
        static let effect: UInt16 = 0x172D
        /// R G B intensity read by the firmware's static and breathing modes.
        static let color: UInt16 = 0x1741
        /// R G B intensity shown live while in static mode, with no blink.
        static let live: UInt16 = 0x1189
    }
    /// Two BCD bytes.
    private static let firmwareAddress: UInt16 = 0x0030

    let hid: IOHIDDevice
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var reads: [(packet: [UInt8], length: Int, done: ([UInt8]?) -> Void)] = []
    private var inflight: (length: Int, done: ([UInt8]?) -> Void)?
    private var timeout: DispatchWorkItem?

    init?(_ hid: IOHIDDevice) {
        guard IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.hid = hid
        IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(hid, inBuf, 64, { ctx, _, _, _, reportID, report, length in
            guard let ctx, reportID == 5 else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<KrakenLink>.fromOpaque(ctx).takeUnretainedValue().handle(bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func close() {
        timeout?.cancel()
        IOHIDDeviceRegisterInputReportCallback(hid, inBuf, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        let pending = reads.map { $0.done } + [inflight?.done].compactMap { $0 }
        reads = []; inflight = nil
        pending.forEach { $0(nil) }
    }

    deinit { inBuf.deallocate() }

    @discardableResult
    func write(_ address: UInt16, _ data: [UInt8]) -> Bool {
        var packet = Self.packet(.writeRAM, address, length: data.count)
        packet.replaceSubrange(5..<(5 + data.count), with: data)
        return IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, 0x04, packet, packet.count) == kIOReturnSuccess
    }

    func readRAM(_ address: UInt16, length: Int, done: @escaping ([UInt8]?) -> Void) {
        enqueue(Self.packet(.readRAM, address, length: length), length, done)
    }

    func readFirmware(done: @escaping (String?) -> Void) {
        enqueue(Self.packet(.readEEPROM, Self.firmwareAddress, length: 2), 2) { data in
            done(data.map { String(format: "%x.%02x", $0[0], $0[1]) })
        }
    }

    private static func packet(_ destination: Destination, _ address: UInt16, length: Int) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 37)
        packet[0] = 0x04
        packet[1] = destination.rawValue
        packet[2] = UInt8(length)
        packet[3] = UInt8(address >> 8)
        packet[4] = UInt8(address & 0xFF)
        return packet
    }

    private func enqueue(_ packet: [UInt8], _ length: Int, _ done: @escaping ([UInt8]?) -> Void) {
        reads.append((packet, length, done))
        pump()
    }

    private func pump() {
        guard inflight == nil, !reads.isEmpty else { return }
        let next = reads.removeFirst()
        guard IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, 0x04, next.packet, next.packet.count) == kIOReturnSuccess else {
            next.done(nil)
            return pump()
        }
        inflight = (next.length, next.done)
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handle(_ report: [UInt8]) {
        guard let inflight, report.count > inflight.length else { return }
        finish(Array(report[1...inflight.length]))
    }

    private func finish(_ data: [UInt8]?) {
        timeout?.cancel()
        let done = inflight?.done
        inflight = nil
        done?(data)
        pump()
    }
}

/// Values of the effect byte (openrazer's bitfield: 1 on, 2 breathing, 4 spectrum, 8 sync).
enum KrakenEffect: UInt8, CaseIterable, Identifiable {
    case solid = 0x01, breathing = 0x0B, spectrum = 0x05, off = 0x00
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .solid: "Estático"
        case .breathing: "Respiración"
        case .spectrum: "Espectro"
        case .off: "Apagado"
        }
    }
    var usesColor: Bool { self == .solid || self == .breathing }

    init(byte: UInt8) {
        if byte & 0x32 != 0 { self = .breathing }
        else if byte & 0x04 != 0 { self = .spectrum }
        else if byte & 0x01 != 0 { self = .solid }
        else { self = .off }
    }
}

final class KrakenDevice: ObservableObject, Identifiable {
    static let name = "Razer Kraken Ultimate"
    static let transitionSeconds = 1.5

    let link: KrakenLink
    var id: Int { KrakenLink.productID }

    @Published private(set) var firmware = ""
    @Published private(set) var effect: KrakenEffect = .spectrum
    @Published private(set) var color = RGB.razerGreen
    @Published var brightness = 255

    /// What the LEDs show right now, so a transition can start from there even if one is running.
    private var shown = RGB.razerGreen
    /// The firmware only shows a new static colour once effects have been cleared (openrazer
    /// issue 1606). After that, RAM.live updates the LEDs directly, so the clear happens only
    /// when entering static mode.
    private var liveReady = false
    private var transition: Timer?
    private var pendingColor: DispatchWorkItem?

    init(link: KrakenLink) { self.link = link }

    func refresh(done: (() -> Void)? = nil) {
        link.readFirmware { [weak self] in if let v = $0 { self?.firmware = v } }
        link.readRAM(KrakenLink.RAM.effect, length: 1) { [weak self] in
            if let v = $0 { self?.effect = KrakenEffect(byte: v[0]) }
        }
        link.readRAM(KrakenLink.RAM.color, length: 4) { [weak self] in
            if let self, let v = $0 {
                self.color = RGB(bytes: v[0..<3])
                self.shown = self.color
                self.brightness = max(Int(v[3]), 1)
            }
            done?()
        }
    }

    // MARK: Writes (only on user action)

    func setEffect(_ new: KrakenEffect) {
        cancelPending()
        effect = new
        switch new {
        case .solid:
            transition(to: color)
        case .breathing:
            applyBreathing()
        case .spectrum, .off:
            liveReady = false
            link.write(KrakenLink.RAM.effect, [new.rawValue])
        }
    }

    /// Selectors fire continuously while dragging, so this waits for the value to settle.
    func pickColor(_ new: RGB) {
        color = new
        pendingColor?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.effect {
            case .solid: self.transition(to: new)
            case .breathing: self.applyBreathing()
            case .spectrum, .off: break
            }
        }
        pendingColor = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Sets the colour the next effect change will use, without animating.
    func pickColorNow(_ new: RGB) {
        color = new
    }

    func commitBrightness() {
        guard effect == .solid, transition == nil else { return }
        let data = color.bytes + [intensity]
        link.write(KrakenLink.RAM.live, data)
        link.write(KrakenLink.RAM.color, data)
    }

    private var intensity: UInt8 { UInt8(min(max(brightness, 1), 255)) }

    private func cancelPending() {
        pendingColor?.cancel()
        pendingColor = nil
        transition?.invalidate()
        transition = nil
    }

    private func applyBreathing() {
        cancelPending()
        liveReady = false
        link.write(KrakenLink.RAM.effect, [0x00])
        usleep(15_000)
        link.write(KrakenLink.RAM.color, color.bytes)
        usleep(45_000)
        link.write(KrakenLink.RAM.effect, [KrakenEffect.breathing.rawValue])
    }

    /// One rainbow pass from the colour on the LEDs to `target`, then holds `target`.
    private func transition(to target: RGB) {
        cancelPending()
        let from = shown
        if !liveReady {
            link.write(KrakenLink.RAM.effect, [0x00])
            usleep(15_000)
            link.write(KrakenLink.RAM.live, from.bytes + [intensity])
            link.write(KrakenLink.RAM.effect, [KrakenEffect.solid.rawValue])
            usleep(15_000)
            liveReady = true
        }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Date().timeIntervalSince(start) / Self.transitionSeconds
            if t >= 1 {
                self.finishTransition(target)
            } else {
                self.shown = Self.rainbow(from: from, to: target, at: t)
                self.link.write(KrakenLink.RAM.live, self.shown.bytes + [self.intensity])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        transition = timer
    }

    private func finishTransition(_ target: RGB) {
        transition?.invalidate()
        transition = nil
        shown = target
        let data = target.bytes + [intensity]
        link.write(KrakenLink.RAM.live, data)
        link.write(KrakenLink.RAM.color, data)
    }

    /// Runs the hue wheel from `from` to `to`, at least half a turn, easing out of and into the
    /// two ends so whites and greys don't jump.
    static func rainbow(from: RGB, to: RGB, at t: Double) -> RGB {
        let start = from.hue
        var turn = (to.hue - start).truncatingRemainder(dividingBy: 1)
        if turn < 0 { turn += 1 }
        if turn < 0.5 { turn += 1 }
        let wheel = RGB.hue(start + turn * t)
        let edge = 0.12
        if t < edge { return from.mixed(with: wheel, t / edge) }
        if t > 1 - edge { return to.mixed(with: wheel, (1 - t) / edge) }
        return wheel
    }
}

private extension RGB {
    var hue: Double { NSColor(srgbRed: r, green: g, blue: b, alpha: 1).hueComponent }
    func mixed(with other: RGB, _ k: Double) -> RGB {
        RGB(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k)
    }
}

final class KrakenManager: ObservableObject {
    @Published private(set) var device: KrakenDevice?
    var onConnected: ((KrakenDevice) -> Void)?
    var onDisconnected: ((KrakenDevice) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: KrakenLink.vendorID,
            kIOHIDProductIDKey: KrakenLink.productID,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<KrakenManager>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<KrakenManager>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ hid: IOHIDDevice) {
        guard device == nil, let link = KrakenLink(hid) else { return }
        let entry = KrakenDevice(link: link)
        device = entry
        entry.refresh { [weak self] in self?.onConnected?(entry) }
    }

    private func detach(_ hid: IOHIDDevice) {
        guard let entry = device, entry.link.hid == hid else { return }
        device = nil
        entry.link.close()
        onDisconnected?(entry)
    }
}

/// Menu section for the Kraken.
struct KrakenDeviceView: View {
    @ObservedObject var device: KrakenDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                DeviceHero(image: nil, symbol: "headphones", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KrakenDevice.name).font(.headline)
                    Text(device.firmware.isEmpty ? "Conectado por USB" : "Conectado por USB · FW \(device.firmware)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Iluminación Chroma", systemImage: "light.max").font(.subheadline.weight(.semibold))
                Picker("Efecto", selection: Binding(get: { device.effect }, set: { device.setEffect($0) })) {
                    ForEach(KrakenEffect.allCases) { Text($0.title).tag($0) }
                }
                if device.effect.usesColor {
                    ColorRow(title: "Color", selection: Binding(get: { device.color }, set: { device.pickColor($0) }))
                }
                if device.effect == .solid {
                    HStack {
                        Text("Brillo").frame(width: 70, alignment: .leading)
                        Slider(value: Binding(get: { Double(device.brightness) }, set: { device.brightness = Int($0.rounded()) }),
                               in: 1...255,
                               onEditingChanged: { if !$0 { device.commitBrightness() } })
                    }
                }
            }
        }
    }
}

/// `Synapseless --kraken-test`: runs every lighting path on the real headset for someone to watch,
/// then restores what it found and quits.
struct KrakenSelfTest {
    let manager: KrakenManager

    func run(tries: Int = 20) {
        guard let device = manager.device, !device.firmware.isEmpty else {
            if tries == 0 { log("FAIL no Kraken"); NSApp.terminate(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(tries: tries - 1) }
            return
        }
        let original = (effect: device.effect, color: device.color, brightness: device.brightness)
        log("fw=\(device.firmware) effect=\(original.effect.title) color=\(original.color.bytes) brightness=\(original.brightness)")

        let red = RGB(r: 1, g: 0, b: 0), blue = RGB(r: 0, g: 0, b: 1), purple = RGB(r: 0.69, g: 0, b: 1)
        let steps: [(String, Double, () -> Void)] = [
            ("1 estatico: transicion a rojo", 4, { device.setEffect(.solid); device.pickColor(red) }),
            ("2 brillo bajo", 3, { device.brightness = 40; device.commitBrightness() }),
            ("3 brillo maximo", 3, { device.brightness = 255; device.commitBrightness() }),
            ("4 espectro", 4, { device.setEffect(.spectrum) }),
            ("5 de espectro a azul con transicion", 4, { device.pickColorNow(blue); device.setEffect(.solid) }),
            ("6 blanco con transicion", 4, { device.pickColor(RGB(r: 1, g: 1, b: 1)) }),
            ("7 respiracion morada", 6, { device.pickColorNow(purple); device.setEffect(.breathing) }),
            ("8 apagado", 3, { device.setEffect(.off) }),
        ]
        var delay = 0.0
        for (name, seconds, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { log(name); action() }
            delay += seconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            log("restaurando")
            device.brightness = original.brightness
            device.pickColorNow(original.color)
            device.setEffect(original.effect)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 2) {
            device.refresh {
                log("final effect=\(device.effect.title) color=\(device.color.bytes) brightness=\(device.brightness)")
                NSApp.terminate(nil)
            }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardOutput.write(Data(("[kraken-test] " + s + "\n").utf8))
    }
}

