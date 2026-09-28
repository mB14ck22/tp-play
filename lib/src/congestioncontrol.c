// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/congestioncontrol.h>

#define CONGESTION_CONTROL_INTERVAL_MS 200
#define CONGESTION_RECOVERY_ENTER_LOSS 0.20
#define CONGESTION_RECOVERY_EXIT_LOSS 0.02
#define CONGESTION_RECOVERY_ENTER_SAMPLES 3
#define CONGESTION_RECOVERY_EXIT_SAMPLES 5
#define CONGESTION_RECOVERY_PULSE_INTERVAL_SAMPLES 5

static void *congestion_control_thread_func(void *user)
{
	ChiakiCongestionControl *control = user;
	chiaki_thread_set_affinity(CHIAKI_THREAD_NAME_CONGESTION);

	ChiakiErrorCode err = chiaki_bool_pred_cond_lock(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return NULL;

	while(true)
	{
		err = chiaki_bool_pred_cond_timedwait(&control->stop_cond, CONGESTION_CONTROL_INTERVAL_MS);
		if(err != CHIAKI_ERR_TIMEOUT)
			break;

		uint64_t received;
		uint64_t lost;
		chiaki_packet_stats_get(control->stats, true, &received, &lost);
		ChiakiTakionCongestionPacket packet = { 0 };
		uint64_t total = received + lost;
		control->packet_loss = total > 0 ? (double)lost / total : 0;

		/* Keep the configured quality ceiling during healthy delivery. If a
		 * sustained burst is clearly starving video, pulse a stronger report at
		 * most once per second. Reporting it every 200 ms makes the console apply
		 * several reductions before the path can react and overshoots to its
		 * minimum bitrate. */
		bool recovery_pulse = false;
		if(total > 0 && control->packet_loss >= CONGESTION_RECOVERY_ENTER_LOSS)
		{
			control->severe_loss_samples++;
			control->recovery_samples = 0;
			if(!control->recovery_mode && control->severe_loss_samples >= CONGESTION_RECOVERY_ENTER_SAMPLES)
			{
				control->recovery_mode = true;
				control->recovery_cooldown_samples = 0;
				CHIAKI_LOGW(control->takion->log, "Congestion recovery enabled after sustained packet loss");
			}
			if(control->recovery_mode)
			{
				if(control->recovery_cooldown_samples == 0)
				{
					recovery_pulse = true;
					control->recovery_cooldown_samples = CONGESTION_RECOVERY_PULSE_INTERVAL_SAMPLES - 1;
				}
				else
					control->recovery_cooldown_samples--;
			}
		}
		else
		{
			control->severe_loss_samples = 0;
			if(control->recovery_cooldown_samples > 0)
				control->recovery_cooldown_samples--;
			if(control->recovery_mode && total > 0 && control->packet_loss <= CONGESTION_RECOVERY_EXIT_LOSS)
			{
				control->recovery_samples++;
				if(control->recovery_samples >= CONGESTION_RECOVERY_EXIT_SAMPLES)
				{
					control->recovery_mode = false;
					control->recovery_samples = 0;
					control->recovery_cooldown_samples = 0;
					CHIAKI_LOGI(control->takion->log, "Congestion recovery disabled after stable delivery");
				}
			}
			else if(total > 0)
				control->recovery_samples = 0;
		}

		double reported_loss = chiaki_congestion_control_reported_loss(
			control->packet_loss, control->packet_loss_max, recovery_pulse);
		if(control->sample_count++ % 5 == 0)
			CHIAKI_LOGI(control->takion->log,
				"Congestion feedback: received=%llu lost=%llu measured_loss=%.1f%% reported_loss=%.1f%% recovery=%s pulse=%s",
				(unsigned long long)received, (unsigned long long)lost,
				control->packet_loss * 100.0, reported_loss * 100.0,
				control->recovery_mode ? "on" : "off",
				recovery_pulse ? "yes" : "no");
		lost = (uint64_t)((double)total * reported_loss);
		received = total - lost;
		packet.received = (uint16_t)received;
		packet.lost = (uint16_t)lost;
		CHIAKI_LOGV(control->takion->log, "Sending Congestion Control Packet, received: %u, lost: %u",
			(unsigned int)packet.received, (unsigned int)packet.lost);
		chiaki_takion_send_congestion(control->takion, &packet);
	}

	chiaki_bool_pred_cond_unlock(&control->stop_cond);
	return NULL;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_start(ChiakiCongestionControl *control, ChiakiTakion *takion, ChiakiPacketStats *stats, double packet_loss_max)
{
	control->takion = takion;
	control->stats = stats;
	control->packet_loss_max = packet_loss_max;
	control->packet_loss = 0;
	control->sample_count = 0;
	control->severe_loss_samples = 0;
	control->recovery_samples = 0;
	control->recovery_cooldown_samples = 0;
	control->recovery_mode = false;

	ChiakiErrorCode err = chiaki_bool_pred_cond_init(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	err = chiaki_thread_create(&control->thread, congestion_control_thread_func, control);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		chiaki_bool_pred_cond_fini(&control->stop_cond);
		return err;
	}

	chiaki_thread_set_name(&control->thread, "Chiaki Congestion Control");

	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_stop(ChiakiCongestionControl *control)
{
	ChiakiErrorCode err = chiaki_bool_pred_cond_signal(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	err = chiaki_thread_join(&control->thread, NULL);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	control->thread.thread = 0;

	return chiaki_bool_pred_cond_fini(&control->stop_cond);
}
