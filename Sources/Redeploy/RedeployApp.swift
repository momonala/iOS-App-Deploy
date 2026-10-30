import SwiftUI

@main
struct RedeployApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: delegate.model)
        } label: {
            Image(nsImage: .menuBarIcon(delegate.model.menuBarSymbol))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(notifier: Notifier())

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

private extension NSImage {
    static func menuBarIcon(_ symbolName: String) -> NSImage {
        let targetHeight = NSStatusBar.system.thickness - 2
        let config = NSImage.SymbolConfiguration(pointSize: targetHeight, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return NSImage() }
        let scale = targetHeight / symbol.size.height
        let size = NSSize(width: (symbol.size.width * scale).rounded(.up), height: targetHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "iOS App Deploy"
        return image
    }
}
