// modeprobe <w> <h> [hold-secs] [target-hz]
// Switch the main display to the HiDPI mode that looks like <w>x<h> (session only), sample the driver's present
// counters, then switch EXPLICITLY back to the native 1:1 mode (not CGRestorePermanentDisplayConfiguration, which
// was seen to leave the hardware in the scaled mode), sample again, and finally restore the permanent config.
import CoreGraphics
import Foundation

func sysctlInt(_ name: String) -> Int64 {
    var v: Int64 = 0; var n = MemoryLayout<Int64>.size
    if sysctlbyname(name, &v, &n, nil, 0) != 0 { return -1 }
    if n == 4 { return Int64(Int32(truncatingIfNeeded: v)) }
    return v
}
func sample(_ tag: String, _ secs: Double) {
    let k = ["debug.nvaccel_iop_ok", "debug.nvaccel_iop_blank", "debug.nvaccel_iop_fail", "debug.nvaccel_iop_empty", "debug.nvaccel_iop_src_res"]
    let a = k.map(sysctlInt); Thread.sleep(forTimeInterval: secs); let b = k.map(sysctlInt)
    let d = zip(a, b).map { $1 - $0 }
    let m = CGDisplayCopyDisplayMode(CGMainDisplayID())!
    print(String(format: "%@ [%dx%d px %dx%d]: ok +%lld blank +%lld fail +%lld empty +%lld res +%lld", tag,
                 m.width, m.height, m.pixelWidth, m.pixelHeight, d[0], d[1], d[2], d[3], d[4]))
    fflush(stdout)
}
func set(_ m: CGDisplayMode) -> Int32 {
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, CGMainDisplayID(), m, nil)
    return CGCompleteDisplayConfiguration(cfg, .forSession).rawValue
}

let a = CommandLine.arguments
guard a.count >= 3, let w = Int(a[1]), let h = Int(a[2]) else { print("usage: modeprobe <w> <h> [hold]"); exit(2) }
let hold = a.count > 3 ? Double(a[3]) ?? 6 : 6
let hz = a.count > 4 ? Int(a[4]) ?? 0 : 0
let lowres = a.count > 5 && a[5] == "lo"
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
let cur = CGDisplayCopyDisplayMode(d)!
guard let native = modes.first(where: { $0.width == cur.pixelWidth && $0.height == cur.pixelHeight && $0.pixelWidth == $0.width && Int($0.refreshRate) == Int(cur.refreshRate) }),
      let target = modes.filter({ $0.width == w && $0.height == h && (lowres ? $0.pixelWidth == $0.width : $0.pixelWidth > $0.width) && Int($0.refreshRate) == (hz > 0 ? hz : Int(cur.refreshRate)) }).first
else { print("mode not found"); exit(3) }
print("native id 0x\(String(native.ioDisplayModeID, radix: 16)), target id 0x\(String(target.ioDisplayModeID, radix: 16))")
sample("baseline", 2)
print("set target ->", set(target)); fflush(stdout)
sample("target t+0..3", 3)
sample("target t+3..\(Int(hold))", max(1, hold - 3))
print("set native ->", set(native)); fflush(stdout)
sample("native t+0..3", 3)
sample("native t+3..6", 3)
CGRestorePermanentDisplayConfiguration()
sample("restored", 2)
