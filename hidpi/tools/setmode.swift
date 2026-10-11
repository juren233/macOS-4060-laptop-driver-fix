// setmode <w> <h> [hi|lo] -- permanently switch the main display to the "looks like" <w>x<h> mode at the current Hz
// (hi = HiDPI backing, lo = 1:1), then restart Finder so its windows are drawn fresh in the new mode.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 3, let w = Int(a[1]), let h = Int(a[2]) else { print("usage: setmode <w> <h> [hi|lo]"); exit(2) }
let lo = a.count > 3 && a[3] == "lo"
let d = CGMainDisplayID(), cur = CGDisplayCopyDisplayMode(d)!
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
guard let m = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? []).first(where: {
    $0.width == w && $0.height == h && (lo ? $0.pixelWidth == $0.width : $0.pixelWidth > $0.width) && Int($0.refreshRate) == Int(cur.refreshRate) })
else { print("mode not found"); exit(3) }
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg); CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
print("set \(w)x\(h) (\(m.pixelWidth)x\(m.pixelHeight)) ->", CGCompleteDisplayConfiguration(cfg, .permanently).rawValue)
Thread.sleep(forTimeInterval: 2)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["Finder"]; try? p.run(); p.waitUntilExit()
