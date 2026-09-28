// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_CONGESTIONCONTROL_H
#define CHIAKI_CONGESTIONCONTROL_H

#include "takion.h"
#include "thread.h"
#include "packetstats.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct chiaki_congestion_control_t
{
	ChiakiTakion *takion;
	ChiakiPacketStats *stats;
	ChiakiThread thread;
	ChiakiBoolPredCond stop_cond;
	double packet_loss;
	double packet_loss_max;
	uint32_t sample_count;
	uint32_t severe_loss_samples;
	uint32_t recovery_samples;
	uint32_t recovery_cooldown_samples;
	bool recovery_mode;
} ChiakiCongestionControl;

/* Preserve a caller's uncapped delivery feedback even during legacy recovery
 * pulses. In particular, recovery must never report LESS loss than normal. */
static inline double chiaki_congestion_control_reported_loss(double measured, double maximum, bool recovery_pulse)
{
	if(recovery_pulse && maximum < 0.10)
		maximum = 0.10;
	return measured < maximum ? measured : maximum;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_start(ChiakiCongestionControl *control, ChiakiTakion *takion, ChiakiPacketStats *stats, double packet_loss_max);

/**
 * Stop control and join the thread
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_stop(ChiakiCongestionControl *control);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CONGESTIONCONTROL_H
