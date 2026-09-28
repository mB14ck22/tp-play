#include <assert.h>
#include <stdio.h>
#include <chiaki/congestioncontrol.h>

int main(void)
{
    // iOS: healthy delivery must not invent congestion; real congestion must
    // not disappear during startup, legacy recovery pulses, or recovery exit.
    const double losses[] = {0.0, 0.01, 0.05, 0.20, 0.428, 0.90, 1.0};
    for(unsigned i = 0; i < sizeof(losses) / sizeof(losses[0]); i++) {
        assert(chiaki_congestion_control_reported_loss(losses[i], 1.0, false) == losses[i]);
        assert(chiaki_congestion_control_reported_loss(losses[i], 1.0, true) == losses[i]);
    }
    // Other clients retaining the old quality cap keep their existing policy.
    assert(chiaki_congestion_control_reported_loss(0.428, 0.05, false) == 0.05);
    assert(chiaki_congestion_control_reported_loss(0.428, 0.05, true) == 0.10);
    assert(chiaki_congestion_control_reported_loss(0.01, 0.05, true) == 0.01);
    puts("low-latency congestion feedback: PASS (17 checks)");
}
