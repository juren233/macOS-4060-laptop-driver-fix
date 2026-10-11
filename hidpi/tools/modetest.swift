// modetest list                      — list modes of the main display (HiDPI marked)
// modetest try <w> <h> [hz] [secs]   — switch for this session only, revert after secs (default 15)
// The switch uses CGConfigureOption.forSession, so macOS also reverts it if this process dies.
import CoreGraphics
import Foundation

let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
func desc(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth > m.width ? " HiDPI" : ""
    return "\(m.width)x\(m.height) (px \(m.pixelWidth)x\(m.pixelHeight)) @\(Int(m.refreshRate))Hz\(hidpi)"
}
let args = CommandLine.arguments
guard let cur = CGDisplayCopyDisplayMode(d) else { print("no current mode"); exit(1) }

if args.count < 2 || args[1] == "list" {
    print("current:", desc(cur))
    var seen = Set<String>()
    for m in modes.sorted(by: { ($0.pixelWidth > $0.width ? 0 : 1, -$0.width) < ($1.pixelWidth > $1.width ? 0 : 1, -$1.width) }) {
        let s = desc(m); if seen.insert(s).inserted { print("  ", s) }
    }
    exit(0)
}

guard args[1] == "try", args.count >= 4, let w = Int(args[2]), let h = Int(args[3]) else {
    print("usage: modetest list | modetest try <w> <h> [hz] [secs]"); exit(2)
}
let hz = args.count > 4 ? Double(args[4]) : nil
let secs = args.count > 5 ? UInt32(args[5]) ?? 15 : 15
let cands = modes.filter { $0.width == w && $0.height == h && (hz == nil || Int($0.refreshRate) == Int(hz!)) }
guard let target = cands.max(by: { $0.pixelWidth < $1.pixelWidth }) else { print("no such mode"); exit(3) }

var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayWithDisplayMode(cfg, d, target, nil)
let err = CGCompleteDisplayConfiguration(cfg, .forSession)
print("switched to", desc(target), "err", err.rawValue, "— reverting in \(secs)s")
fflush(stdout)
sleep(secs)
CGRestorePermanentDisplayConfiguration()
print("reverted to", desc(CGDisplayCopyDisplayMode(d)!))
