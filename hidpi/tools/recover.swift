// recover: force a real mode change (40 Hz native, then 165 Hz native), committed permanently, and report blank frames.
import CoreGraphics
import Foundation
func ctr(_ n: String) -> Int64 { var v: Int64 = 0; var s = 8; sysctlbyname(n, &v, &s, nil, 0); return v }
func blankRate(_ secs: Double) -> String { let o = ctr("debug.nvaccel_iop_ok"), b = ctr("debug.nvaccel_iop_blank"); Thread.sleep(forTimeInterval: secs)
    return "ok +\(ctr("debug.nvaccel_iop_ok") - o) blank +\(ctr("debug.nvaccel_iop_blank") - b)" }
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
func find(_ hz: Int) -> CGDisplayMode? { modes.first { $0.width == 2560 && $0.height == 1440 && $0.pixelWidth == 2560 && Int($0.refreshRate) == hz } }
func set(_ m: CGDisplayMode) -> Int32 { var c: CGDisplayConfigRef?; CGBeginDisplayConfiguration(&c); CGConfigureDisplayWithDisplayMode(c, d, m, nil); return CGCompleteDisplayConfiguration(c, .permanently).rawValue }
guard let m40 = find(40), let m165 = find(165) else { print("modes missing"); exit(1) }
print("ids 40Hz 0x\(String(UInt32(bitPattern: m40.ioDisplayModeID), radix: 16)) 165Hz 0x\(String(UInt32(bitPattern: m165.ioDisplayModeID), radix: 16))")
print("before:", blankRate(2))
print("set 40Hz ->", set(m40)); Thread.sleep(forTimeInterval: 2); print("at 40Hz:", blankRate(2))
print("set 165Hz ->", set(m165)); Thread.sleep(forTimeInterval: 2); print("at 165Hz:", blankRate(3))
