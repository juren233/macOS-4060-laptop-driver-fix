// listmodes: every mode of the main display -- looks-like size, backing pixels, Hz, usable for the desktop
import CoreGraphics
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
for m in (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), opts) as? [CGDisplayMode] ?? []) {
  print(m.width, m.height, m.pixelWidth, m.pixelHeight, Int(m.refreshRate), m.isUsableForDesktopGUI() ? "gui" : "-")
}
