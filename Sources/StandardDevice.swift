import AppKit
import IOKit.hid

/// Razer's "standard" protocol used by mice, keyboards and Blade laptops (rzDevice25 in Synapse):
/// one 90-byte feature report, ID 0, written and then read back.
///
///   0 status   1 transaction   2-3 remaining packets   4 protocol   5 data size   6 class   7 id
///   8…87 arguments   88 XOR(bytes 2…87)   89 reserved
///
/// Reply status: 0x02 ok, 0x01 busy (poll again), 0x03 failed, 0x04 timeout, 0x05 not supported.
/// UNTESTED: written from Synapse's driver and openrazer's documentation, never run on real hardware.
final class StandardLink {
    let hid: IOHIDDevice
    private let queue = DispatchQueue(label: "synapseless.standard")
    private var transaction: UInt8 = 0

    init?(_ hid: IOHIDDevice) {
        guard IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.hid = hid
    }

    func close() { IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone)) }

    /// Sends one command off the main thread and hands the reply's arguments back on main (nil on failure).
    func send(_ command: (size: UInt8, cls: UInt8, id: UInt8), _ args: [UInt8] = [],
              done: (([UInt8]?) -> Void)? = nil) {
        queue.async { [self] in
            let reply = exchange(command, args)
            DispatchQueue.main.async { done?(reply) }
        }
    }

    private func exchange(_ command: (size: UInt8, cls: UInt8, id: UInt8), _ args: [UInt8]) -> [UInt8]? {
        // Synapse cycles the transaction ID through 0…30.
        transaction = transaction >= 30 ? 0 : transaction + 1
        var packet = [UInt8](repeating: 0, count: 90)
        packet[1] = transaction
        packet[5] = max(command.size, UInt8(args.count))
        packet[6] = command.cls
        packet[7] = command.id
        for (i, b) in args.prefix(80).enumerated() { packet[8 + i] = b }
        packet[88] = packet[2..<88].reduce(0, ^)

        guard IOHIDDeviceSetReport(hid, kIOHIDReportTypeFeature, 0, &packet, packet.count) == kIOReturnSuccess else {
            return nil
        }
        for _ in 0..<10 {
            usleep(15_000)
            var reply = [UInt8](repeating: 0, count: 90)
            var length = CFIndex(reply.count)
            guard IOHIDDeviceGetReport(hid, kIOHIDReportTypeFeature, 0, &reply, &length) == kIOReturnSuccess,
                  length >= 90 else { return nil }
            switch reply[0] {
            case 0x01: continue
            case 0x02 where reply[6] == command.cls && reply[7] == command.id:
                return Array(reply[8..<88])
            default:
                return nil
            }
        }
        return nil
    }
}

/// Command table: (data size, class, id). Getters have the id's high bit set.
enum StandardCommand {
    static let firmware: (UInt8, UInt8, UInt8) = (0x02, 0x00, 0x81)
    static let battery: (UInt8, UInt8, UInt8) = (0x02, 0x07, 0x80)
    static let charging: (UInt8, UInt8, UInt8) = (0x02, 0x07, 0x84)
    static let getDPI: (UInt8, UInt8, UInt8) = (0x07, 0x04, 0x85)
    static let setDPI: (UInt8, UInt8, UInt8) = (0x07, 0x04, 0x05)
    static let getPolling: (UInt8, UInt8, UInt8) = (0x01, 0x00, 0x85)
    static let setPolling: (UInt8, UInt8, UInt8) = (0x01, 0x00, 0x05)
    // Extended matrix (class 0x0F); LED 0x00 addresses the whole device.
    static let extGetBrightness: (UInt8, UInt8, UInt8) = (0x03, 0x0F, 0x84)
    static let extSetBrightness: (UInt8, UInt8, UInt8) = (0x03, 0x0F, 0x04)
    static let extSetEffect: (UInt8, UInt8, UInt8) = (0x0C, 0x0F, 0x02)
    // Standard matrix (class 0x03); LED 0x05 is the backlight.
    static let stdGetBrightness: (UInt8, UInt8, UInt8) = (0x03, 0x03, 0x83)
    static let stdSetBrightness: (UInt8, UInt8, UInt8) = (0x03, 0x03, 0x03)
    static let stdSetEffect: (UInt8, UInt8, UInt8) = (0x50, 0x03, 0x0A)
    // Blade laptops keep their keyboard brightness in class 0x0E.
    static let bladeGetBrightness: (UInt8, UInt8, UInt8) = (0x02, 0x0E, 0x84)
    static let bladeSetBrightness: (UInt8, UInt8, UInt8) = (0x02, 0x0E, 0x04)
}

enum StandardEffect: String, CaseIterable, Identifiable {
    case solid, breathing, breathingRandom, spectrum, wave, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "Estático"
        case .breathing: "Respiración"
        case .breathingRandom: "Respiración aleatoria"
        case .spectrum: "Espectro"
        case .wave: "Ola"
        case .off: "Apagado"
        }
    }
    var usesColor: Bool { self == .solid || self == .breathing }
}

/// One connected mouse, keyboard or laptop from RazerModel.all.
final class StandardDevice: ObservableObject, Identifiable {
    let model: RazerModel
    let link: StandardLink
    var id: Int { model.pid }

    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var firmware = ""
    @Published var brightness = 255
    @Published var effect: StandardEffect = .spectrum
    @Published var color = RGB.razerGreen
    @Published var dpi = 800
    @Published private(set) var polling: Int?

    init(model: RazerModel, link: StandardLink) {
        self.model = model
        self.link = link
    }

    /// Edition 0's render if the dump had one, else nil (the UI falls back to an SF Symbol).
    var image: NSImage? {
        guard let edition = model.editions.first,
              let url = Bundle.main.url(forResource: "\(model.pid)_\(edition)", withExtension: "png", subdirectory: "devices")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    var symbol: String {
        switch model.kind {
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .laptop: "laptopcomputer"
        case .mousepad: "rectangle.portrait"
        case .accessory: "cable.connector"
        }
    }

    // MARK: Reads (safe: nothing here changes the device)

    func refresh() {
        link.send(StandardCommand.firmware) { [weak self] a in
            if let a { self?.firmware = "\(a[0]).\(a[1])" }
        }
        if model.hasBattery { refreshBattery() }
        if model.dpi != nil {
            link.send(StandardCommand.getDPI, [0x00]) { [weak self] a in
                if let a { self?.dpi = Int(a[1]) << 8 | Int(a[2]) }
            }
            if !model.hyperPolling {
                link.send(StandardCommand.getPolling) { [weak self] a in
                    if let a { self?.polling = Self.pollingRate(code: a[0]) }
                }
            }
        }
        switch model.family {
        case .extended:
            link.send(StandardCommand.extGetBrightness, [0x01, 0x00]) { [weak self] a in
                if let a { self?.brightness = Int(a[2]) }
            }
        case .legacy:
            link.send(StandardCommand.stdGetBrightness, [0x01, 0x05]) { [weak self] a in
                if let a { self?.brightness = Int(a[2]) }
            }
        case .blade:
            link.send(StandardCommand.bladeGetBrightness, [0x01]) { [weak self] a in
                if let a { self?.brightness = Int(a[1]) }
            }
        }
    }

    func refreshBattery() {
        link.send(StandardCommand.battery) { [weak self] a in
            if let a { self?.battery = Int((Double(a[1]) / 255 * 100).rounded()) }
        }
        link.send(StandardCommand.charging) { [weak self] a in
            if let a { self?.charging = a[1] == 1 }
        }
    }

    // MARK: Writes (only on user action)

    func applyEffect() {
        let (r, g, b) = (color.bytes[0], color.bytes[1], color.bytes[2])
        switch model.family {
        case .extended:
            // varstore 0x01, LED 0x00, effect, then effect parameters.
            let args: [UInt8]
            switch effect {
            case .off: args = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
            case .solid: args = [0x01, 0x00, 0x01, 0x00, 0x00, 0x01, r, g, b]
            case .breathing: args = [0x01, 0x00, 0x02, 0x01, 0x00, 0x01, r, g, b]
            case .breathingRandom: args = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00]
            case .spectrum: args = [0x01, 0x00, 0x03, 0x00, 0x00, 0x00]
            case .wave: args = [0x01, 0x00, 0x04, 0x01, 0x28, 0x00]
            }
            link.send((UInt8(args.count), StandardCommand.extSetEffect.1, StandardCommand.extSetEffect.2), args)
        case .legacy, .blade:
            let args: [UInt8]
            switch effect {
            case .off: args = [0x00]
            case .solid: args = [0x06, r, g, b]
            case .breathing: args = [0x03, 0x01, r, g, b]
            case .breathingRandom: args = [0x03, 0x03]
            case .spectrum: args = [0x04]
            case .wave: args = [0x01, 0x01]
            }
            link.send((UInt8(args.count), StandardCommand.stdSetEffect.1, StandardCommand.stdSetEffect.2), args)
        }
    }

    func commitBrightness() {
        let v = UInt8(min(max(brightness, 0), 255))
        switch model.family {
        case .extended: link.send(StandardCommand.extSetBrightness, [0x01, 0x00, v])
        case .legacy: link.send(StandardCommand.stdSetBrightness, [0x01, 0x05, v])
        case .blade: link.send(StandardCommand.bladeSetBrightness, [0x01, v])
        }
    }

    func commitDPI() {
        guard let range = model.dpi else { return }
        let value = min(max(dpi, range.lowerBound), range.upperBound)
        let hi = UInt8(value >> 8), lo = UInt8(value & 0xFF)
        link.send(StandardCommand.setDPI, [0x01, hi, lo, hi, lo, 0x00, 0x00]) { [weak self] _ in
            self?.link.send(StandardCommand.getDPI, [0x00]) { a in
                if let a { self?.dpi = Int(a[1]) << 8 | Int(a[2]) }
            }
        }
    }

    func setPolling(_ hz: Int) {
        let code: UInt8 = hz >= 1000 ? 0x01 : hz >= 500 ? 0x02 : 0x08
        link.send(StandardCommand.setPolling, [code]) { [weak self] _ in
            self?.link.send(StandardCommand.getPolling) { a in
                if let a { self?.polling = Self.pollingRate(code: a[0]) }
            }
        }
    }

    private static func pollingRate(code: UInt8) -> Int? {
        switch code {
        case 0x01: 1000
        case 0x02: 500
        case 0x08: 125
        default: nil
        }
    }
}

/// Finds catalog devices as they're plugged in. Opens only the interface that carries the
/// 90-byte feature report, so a mouse's pointer input is never touched.
final class StandardDeviceManager: ObservableObject {
    @Published private(set) var devices: [StandardDevice] = []
    var onConnected: ((StandardDevice) -> Void)?
    var onDisconnected: ((StandardDevice) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var batteryTimer: Timer?

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<StandardDeviceManager>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<StandardDeviceManager>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.devices.filter(\.model.hasBattery).forEach { $0.refreshBattery() }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func attach(_ device: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              let model = RazerModel.byPID[pid],
              let featureSize = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int,
              featureSize >= 90,
              !devices.contains(where: { $0.model.pid == pid }),
              let link = StandardLink(device) else { return }
        let entry = StandardDevice(model: model, link: link)
        devices.append(entry)
        entry.refresh()
        // Give the first reads a moment so the card can show the battery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.onConnected?(entry) }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { $0.link.hid == device }) else { return }
        let entry = devices.remove(at: index)
        entry.link.close()
        onDisconnected?(entry)
    }
}
