// ACProbe: read-only diagnostic. Matches the ACPI0003 AC device, evaluates \_SB.AC._PSR and the EC fields behind it once a second
// and publishes them as IORegistry properties:  ioreg -rn AC -l | grep -E 'probe_'
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

class ACProbe : public IOService {
    OSDeclareDefaultStructors(ACProbe)
    IOACPIPlatformDevice *dev {nullptr};
    IOACPIPlatformDevice *ec {nullptr};
    IOTimerEventSource *timer {nullptr};
    uint32_t tick {0};
    void put(IOACPIPlatformDevice *d, const char *key, const char *path);
    void poll();
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};
OSDefineMetaClassAndStructors(ACProbe, IOService)

void ACProbe::put(IOACPIPlatformDevice *d, const char *key, const char *path) {
    UInt32 v = 0;
    if (!d) { char k[40]; snprintf(k, sizeof(k), "probe_%s_err", key); setProperty(k, (uint64_t)1, 32); return; }
    IOReturn r = d->evaluateInteger(path, &v);
    char k[40]; snprintf(k, sizeof(k), "probe_%s", key);
    if (r == kIOReturnSuccess) setProperty(k, (uint64_t)v, 32);
    else { snprintf(k, sizeof(k), "probe_%s_err", key); setProperty(k, (uint64_t)(uint32_t)r, 32); }
}
void ACProbe::poll() {
    put(dev, "STA",  "_STA");
    put(dev, "ACPS", "ACPS");
    put(dev, "PSR2", "PSR2");
    put(dev, "PSR3", "PSR3");
    put(dev, "ZZZZ", "ZZZZ");
    put(ec,  "STA_ec", "_STA");
    put(dev, "PSR",  "_PSR");
    put(dev, "XPSR", "XPSR");
    put(dev, "PSRabs", "\\_SB_.AC__._PSR");
    { UInt64 v64 = 0; IOReturn r = dev->evaluateInteger("_PSR", &v64); setProperty("probe_PSR64_ret", (uint64_t)(uint32_t)r, 32); setProperty("probe_PSR64", v64, 64); }
    { OSObject *o = nullptr; IOReturn r = dev->evaluateObject("_PSR", &o); setProperty("probe_PSRobj_ret", (uint64_t)(uint32_t)r, 32);
      if (o) { setProperty("probe_PSRobj_class", o->getMetaClass()->getClassName()); o->release(); } }
    { OSObject *o = nullptr; IOReturn r = dev->evaluateObject("XPSR", &o); setProperty("probe_XPSRobj_ret", (uint64_t)(uint32_t)r, 32);
      if (o) { setProperty("probe_XPSRobj_class", o->getMetaClass()->getClassName()); o->release(); } }
    put(dev, "ACFG", "ACFG");
    put(dev, "GPSF", "GPSF");
    put(dev, "ADPabs", "\\_SB_.PC00.LPCB.EC0_.ADP_");   // absolute, 4-char padded
    put(ec,  "ADP",  "ADP_");
    put(ec,  "AFLT", "AFLT");
    put(ec,  "BAT0f","BAT0");
    put(ec,  "B15C", "B15C");
    put(ec,  "ECOK", "ECOK");
    setProperty("probe_tick", (uint64_t)++tick, 32);
    timer->setTimeoutMS(1000);
}
bool ACProbe::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!dev) return false;
    OSDictionary *m = IOService::nameMatching("EC0");
    if (m) { IOService *e = IOService::copyMatchingService(m); m->release(); ec = OSDynamicCast(IOACPIPlatformDevice, e); if (!ec && e) e->release(); }
    setProperty("probe_ec_found", (uint64_t)(ec != nullptr), 32);
    IOWorkLoop *wl = getWorkLoop();
    if (!wl) return false;
    timer = IOTimerEventSource::timerEventSource(this, [](OSObject *o, IOTimerEventSource *) { static_cast<ACProbe *>(o)->poll(); });
    if (!timer || wl->addEventSource(timer) != kIOReturnSuccess) return false;
    timer->setTimeoutMS(500);
    registerService();
    return true;
}
void ACProbe::stop(IOService *provider) {
    if (timer) { timer->cancelTimeout(); getWorkLoop()->removeEventSource(timer); timer->release(); timer = nullptr; }
    if (ec) { ec->release(); ec = nullptr; }
    IOService::stop(provider);
}
