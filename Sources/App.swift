import AppKit
import SwiftUI

@main
struct SynapselessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: delegate.controller, lighting: delegate.controller.lighting, devices: delegate.devices, kraken: delegate.kraken) {
                delegate.showCard()
            }
        } label: {
            MenuBarLabel(controller: delegate.controller, kraken: delegate.kraken)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = HeadsetController()
    let devices = StandardDeviceManager()
    let kraken = KrakenManager()
    private let popup = ConnectPopup()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-docs") {
            let dir = i + 1 < args.count ? args[i + 1] : "docs"
            return DocRenderer(controller: controller, outDir: URL(fileURLWithPath: dir)).run()
        }
        controller.onHeadsetConnected = { [weak self] in self?.showCard() }
        controller.onHeadsetDisconnected = { [weak self] battery, charging in
            guard let self else { return }
            self.popup.show(controller: self.controller, kind: .disconnected(battery: battery, charging: charging))
        }
        controller.start()
        devices.onConnected = { [weak self] device in self?.popup.show(device: device) }
        devices.onDisconnected = { [weak self] device in
            self?.popup.show(device: device, kind: .disconnected(battery: device.battery, charging: device.charging))
        }
        devices.start()
        kraken.onConnected = { [weak self] in self?.popup.show(.kraken($0)) }
        kraken.onDisconnected = { [weak self] in
            self?.popup.show(.kraken($0), kind: .disconnected(battery: nil, charging: false))
        }
        kraken.start()
        if CommandLine.arguments.contains("--kraken-test") { KrakenSelfTest(manager: kraken).run() }
        if CommandLine.arguments.contains("--selftest") { SelfTest(controller: controller).run() }
        if CommandLine.arguments.contains("--demo-cards") { runCardDemo() }
    }

    func showCard() {
        if !controller.dongleConnected, let device = kraken.device { return popup.show(.kraken(device)) }
        popup.show(controller: controller)
    }

    /// `--demo-cards`: the headset card, a catalog mouse joining it, then the mouse powering off.
    private func runCardDemo() {
        guard let mouse = DocRenderer.demoMouse() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showCard() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { self.popup.show(mouse) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
            self.popup.show(mouse, kind: .disconnected(battery: 64, charging: false))
        }
    }
}
