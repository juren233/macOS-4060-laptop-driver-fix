/*
 * AC adapter state for macOS 26. The DSDT's \_SB.AC._PSR (ACPI0003) fails when evaluated by the kernel (kIOReturnError, found
 * with power/ACProbe), so SMCBatteryManager sees no adapter: ExternalConnected = No / "Using Batt" although the charger is plugged
 * in (EC ADP = 1, \_SB.AC.ACFG = 1). ACPI/Patch renames the original method to XPSR (see install-acpsr.sh); this replacement
 * returns ACFG, which the EC query _Q16 / the wake path keep up to date from the EC's ADP bit.
 */
DefinitionBlock ("", "SSDT", 2, "JUREN", "ACPSR", 0x00000000)
{
    External (_SB_.AC__, DeviceObj)
    External (_SB_.AC__.ACFG, IntObj)

    Scope (\_SB.AC)
    {
        Name (ACPS, 0x55)      // sentinel: readable only if this SSDT is loaded (power/ACProbe)
        Method (_PSR, 0, NotSerialized)  // _PSR: Power Source
        {
            Return (ACFG)
        }
        Method (PSR2, 0, NotSerialized) { Return (ACFG) }   // diagnostic twins of _PSR
        Method (PSR3, 0, NotSerialized) { Return (One) }
    }
}
