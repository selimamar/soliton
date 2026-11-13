import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Open at a comfortable size; never narrower than a phone, where the
    // layout is designed to work.
    let windowFrame = NSRect(origin: self.frame.origin, size: NSSize(width: 900, height: 760))
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = NSSize(width: 360, height: 520)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
