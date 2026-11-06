import Foundation

/// `Synapseless --selftest`: exercises every device write against the real headset,
/// checks it by reading back, and restores the original values.
struct SelfTest {
    let controller: HeadsetController

    func run() {
        waitForLink(tries: 20)
    }

    private func log(_ s: String) {
        FileHandle.standardOutput.write(Data(("[selftest] " + s + "\n").utf8))
    }

    private func waitForLink(tries: Int) {
        guard controller.linked, controller.battery != nil, let link = controller.link else {
            if tries == 0 { return log("FAIL headset not linked") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForLink(tries: tries - 1) }
            return
        }
        log("linked battery=\(controller.battery ?? -1) charging=\(controller.charging) fw=\(controller.firmware) " +
            "eq=\(controller.eqPreset.title) bands=\(controller.eqBands) sidetone=\(controller.sidetoneOn)/\(controller.sidetoneLevel) " +
            "powerSave=\(controller.powerSave) edition=\(controller.finish.title) effect=\(controller.lighting.effect.title) brightness=\(controller.brightness)")

        let original = (controller.eqPreset, controller.eqBands)
        let probe = [12, -12, 6, -6, 3, 0, 0, 0, 0, -3]
        link.set(.eqPreset, [EQPreset.custom.rawValue])
        link.set(.eqCurve, probe.map { UInt8(bitPattern: Int8($0)) }) { ok in log("write curve ok=\(ok)") }
        link.get([.eqPreset, .eqCurve]) { r in
            let read = r[.eqCurve]?.map { Int(Int8(bitPattern: $0)) } ?? []
            log("curve wrote \(probe) read \(read) preset=\(r[.eqPreset]?.first.map { String(format: "0x%02x", $0) } ?? "nil")")
            link.set(.eqCurve, original.1.map { UInt8(bitPattern: Int8($0)) })
            link.set(.eqPreset, [original.0.rawValue])
            link.get([.eqPreset, .eqCurve]) { r in
                log("restored preset=\(r[.eqPreset]?.first.map { String(format: "0x%02x", $0) } ?? "nil") curve=\(r[.eqCurve] ?? [])")
                testSidetone(link)
            }
        }
    }

    /// App → headset: pick static red in the engine and read 0x40 back.
    /// Headset → app: write spectrum behind the app's back and wait for the poll to notice.
    private func testLighting(_ link: BarracudaLink) {
        let original = controller.lighting.state
        controller.lighting.effect = .solid
        controller.lighting.color = RGB(r: 1, g: 0, b: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            link.get(.lighting) { p in
                log("app→headset static red: read \(p.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil")")
                link.set(.lighting, [0x03])
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    log("headset→app after external spectrum: app shows \(controller.lighting.effect.title)")
                    controller.lighting.sync(from: original)
                    link.set(.lighting, original.payload)
                    link.get(.lighting) { p in
                        log("restored lighting \(p.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil")")
                        log("DONE")
                    }
                }
            }
        }
    }

    private func testSidetone(_ link: BarracudaLink) {
        let level = UInt8(controller.sidetoneLevel)
        let probe: UInt8 = level == 9 ? 10 : 9
        link.set(.sidetoneLevel, [probe]) { ok in log("sidetone write ok=\(ok)") }
        link.get(.sidetoneLevel) { p in
            log("sidetone wrote \(probe) read \(p?.first.map { "\($0)" } ?? "nil")")
            link.set(.sidetoneLevel, [level])
            link.get(.sidetoneLevel) { p in
                log("sidetone restored \(p?.first.map { "\($0)" } ?? "nil")")
                testLighting(link)
            }
        }
    }
}
