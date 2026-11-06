import Foundation
import IOKit.hid

/// Razer Barracuda X Chroma (1532:0574) through its USB-C dongle.
///
/// Settings travel as 64-byte output/input reports with ID 0x02 on vendor page 0xFF14:
///   GET  02 00 60 00 00 00 04 00 00 80 <prop>
///   SET  02 00 60 00 00 00 <4+n> 00 00 80 <prop|0x80> 00 <n> <data…>
///   byte 62 = XOR(bytes 0…61)
///   reply 02 <status 02=ok> 60 00 00 00 <len> 00 80 80 <prop> 01 <n> <data…>
/// Byte 9 picks the target: 0x80 is the headset, 0x00 the dongle itself.
/// The device also exposes a HID LampArray (6 lamps), but its firmware ignores host updates,
/// so lighting goes through the firmware effects in property 0x40 instead.
/// Everything here runs on the main thread (the device is scheduled on the main run loop).
final class BarracudaLink {
    static let vendorID = 0x1532
    static let productID = 0x0574
    static let lampCount = 6
    static let displayName = "Razer Barracuda X Chroma"

    enum Prop: UInt8 {
        case serial = 0x00, edition = 0x01, firmware = 0x02
        case eqPreset = 0x13, eqCurve = 0x15
        case sidetoneOn = 0x18, sidetoneLevel = 0x19
        case linked = 0x20, battery = 0x21, charging = 0x2A, powerSave = 0x2C
        /// Firmware lighting effect, see LightingState for the encoding.
        case lighting = 0x40
        /// Lighting brightness 0–255; 0 turns the lights off.
        case brightness = 0x41
    }

    /// Byte 9 of a request: who answers it.
    enum Target: UInt8 { case dongle = 0x00, headset = 0x80 }

    let hid: IOHIDDevice
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var queue: [(packet: [UInt8], echo: UInt8, done: ([UInt8]?) -> Void)] = []
    private var inflight: (echo: UInt8, done: ([UInt8]?) -> Void)?
    private var timeout: DispatchWorkItem?

    init?(_ hid: IOHIDDevice) {
        guard IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.hid = hid
        IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(hid, inBuf, 64, { ctx, _, _, _, reportID, report, length in
            guard let ctx, reportID == 2 else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<BarracudaLink>.fromOpaque(ctx).takeUnretainedValue().handle(bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func close() {
        timeout?.cancel()
        IOHIDDeviceRegisterInputReportCallback(hid, inBuf, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        let pending = queue.map { $0.done } + [inflight?.done].compactMap { $0 }
        queue = []; inflight = nil
        pending.forEach { $0(nil) }
    }

    deinit { inBuf.deallocate() }

    // MARK: Vendor properties

    func get(_ prop: Prop, from target: Target = .headset, done: @escaping ([UInt8]?) -> Void) {
        enqueue(Self.packet(prop.rawValue, data: nil, target: target), echo: prop.rawValue, done: done)
    }

    func set(_ prop: Prop, _ data: [UInt8], done: ((Bool) -> Void)? = nil) {
        let code = prop.rawValue | 0x80
        enqueue(Self.packet(code, data: data), echo: code) { done?($0 != nil) }
    }

    /// Reads several properties in order and hands back whatever answered.
    func get(_ props: [Prop], done: @escaping ([Prop: [UInt8]]) -> Void) {
        var results: [Prop: [UInt8]] = [:]
        var remaining = props
        func next() {
            guard !remaining.isEmpty else { return done(results) }
            let prop = remaining.removeFirst()
            get(prop) { payload in
                results[prop] = payload
                next()
            }
        }
        next()
    }

    static func packet(_ code: UInt8, data: [UInt8]?, target: Target = .headset) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 64)
        let payload = data ?? []
        p.replaceSubrange(0..<10, with: [0x02, 0x00, 0x60, 0x00, 0x00, 0x00, UInt8(4 + payload.count), 0x00, 0x00, target.rawValue])
        p[10] = code
        if data != nil {
            p[12] = UInt8(payload.count)
            for (i, b) in payload.enumerated() { p[13 + i] = b }
        }
        p[62] = p[0..<62].reduce(0, ^)
        return p
    }

    private func enqueue(_ packet: [UInt8], echo: UInt8, done: @escaping ([UInt8]?) -> Void) {
        queue.append((packet, echo, done))
        sendNext()
    }

    private func sendNext() {
        guard inflight == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        inflight = (request.echo, request.done)
        var packet = request.packet
        guard IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, 2, &packet, packet.count) == kIOReturnSuccess else {
            return finish(nil)
        }
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func finish(_ payload: [UInt8]?) {
        timeout?.cancel(); timeout = nil
        let done = inflight?.done
        inflight = nil
        done?(payload)
        sendNext()
    }

    private func handle(_ r: [UInt8]) {
        guard r.count >= 13, let current = inflight, r[10] == current.echo else { return }
        guard r[1] == 0x02 else { return finish(nil) }
        finish(Array(r[13..<min(13 + Int(r[12]), 62)]))
    }
}
