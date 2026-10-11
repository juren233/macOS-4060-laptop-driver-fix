/*
 * VoodooPS2Keyboard overrides (RMCF on PS2K) for this Clevo-based laptop.
 *
 * The touchpad key (Fn+F1) is a keyboard-firmware macro: LWin make, F2 make, F2 break, LWin break, all
 * within ~10 ms (set-1 codes e05b 3c bc e0db). "Macro Inversion" folds it into a fake e06e, which the
 * Custom PS2 Map sends to e037, so VoodooPS2's PrtSc handler (RemapPrntScr) toggles the touchpad
 * (kPS2M_setDisableTouchpad -> VoodooI2CHID). The real PrtSc (e037) is moved to F13 (64) first - the
 * map is a single lookup, so it does not chain - leaving it free for a macOS screenshot shortcut.
 * Macro data: ffff, output packet, modifier mask+compare (0 = any), input packets
 * (01 xx = scan code, 02 xx = e0 xx, break = |0x80).
 */
DefinitionBlock ("", "SSDT", 2, "JUREN", "PS2KEYS", 0x00000000)
{
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)

    Scope (_SB.PC00.LPCB.PS2K)
    {
        If (_OSI ("Darwin"))
        {
            Name (RMCF, Package ()
            {
                "Keyboard",
                Package ()
                {
                    "RemapPrntScr",
                    ">y",
                    "Custom PS2 Map",
                    Package ()
                    {
                        Package () {},
                        "e027=0",       // VoodooPS2 defaults (this list replaces them)
                        "e028=0",
                        "e037=64",      // PrtSc -> F13
                        "e06e=e037"     // inverted Fn+F1 -> touchpad toggle
                    },

                    "Macro Inversion",
                    Package ()
                    {
                        Package () {},
                        Buffer () { 0xFF, 0xFF, 0x02, 0x6E, 0x00, 0x00, 0x00, 0x00, 0x02, 0x5B, 0x01, 0x3C },
                        Buffer () { 0xFF, 0xFF, 0x02, 0xEE, 0x00, 0x00, 0x00, 0x00, 0x01, 0xBC, 0x02, 0xDB },
                        Buffer () { 0xFF, 0xFF, 0x02, 0xEE, 0x00, 0x00, 0x00, 0x00, 0x02, 0xDB, 0x01, 0xBC }
                    }
                }
            })
        }
    }
}
