// btpower [0|1]: read / set the Bluetooth controller power preference (private IOBluetooth API, same as blueutil).
#include <stdio.h>
#include <stdlib.h>
int IOBluetoothPreferenceGetControllerPowerState(void);
void IOBluetoothPreferenceSetControllerPowerState(int state);
int main(int argc, char **argv) {
    if (argc > 1) IOBluetoothPreferenceSetControllerPowerState(atoi(argv[1]));
    printf("power %d\n", IOBluetoothPreferenceGetControllerPowerState());
    return 0;
}
