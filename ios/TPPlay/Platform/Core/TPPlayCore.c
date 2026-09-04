#include "TPPlayCore.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>

#include <chiaki/common.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/remote/holepunch.h>

struct TPPlayDiscovery {
	ChiakiDiscoveryService service;
	ChiakiLog log;
	TPPlayDiscoveryCallback callback;
	void *context;
};

struct TPPlayRegistration {
	ChiakiRegist regist;
	ChiakiLog log;
	TPPlayRegistrationCallback callback;
	void *context;
};

struct TPPlaySession {
	ChiakiSession session;
	ChiakiOpusDecoder audio_decoder;
	ChiakiLog log;
	TPPlaySessionEventCallback event_callback;
	TPPlayVideoCallback video_callback;
	TPPlayAudioSettingsCallback audio_settings_callback;
	TPPlayAudioFrameCallback audio_frame_callback;
	void *context;
	bool started;
	atomic_bool logged_first_video_sample;
	atomic_bool logged_audio_settings;
	atomic_bool logged_first_audio_frame;
	atomic_uint_fast64_t video_sample_count;
	ChiakiLog *holepunch_log;
};

struct TPPlayHolepunch {
	ChiakiHolepunchSession session;
	ChiakiLog *log;
};

static pthread_once_t tp_play_core_once = PTHREAD_ONCE_INIT;
static ChiakiErrorCode tp_play_core_init_error = CHIAKI_ERR_UNINITIALIZED;

static void tp_play_initialize_core(void)
{
	tp_play_core_init_error = chiaki_lib_init();
}

static void tp_play_discovery_callback(ChiakiDiscoveryHost *hosts, size_t count, void *context)
{
	TPPlayDiscovery *discovery = context;
	TPPlayHost *result = calloc(count, sizeof(*result));
	if(count > 0 && !result)
		return;

	for(size_t index = 0; index < count; index++)
	{
		ChiakiDiscoveryHost *source = &hosts[index];
		TPPlayHost *destination = &result[index];
		destination->state = (TPPlayHostState)source->state;
		destination->request_port = source->host_request_port;
		destination->address = source->host_addr;
		destination->system_version = source->system_version;
		destination->protocol_version = source->device_discovery_protocol_version;
		destination->name = source->host_name;
		destination->type = source->host_type;
		destination->identifier = source->host_id;
		destination->running_app_title_id = source->running_app_titleid;
		destination->running_app_name = source->running_app_name;
		destination->is_ps5 = chiaki_discovery_host_is_ps5(source);
		destination->target = (int)chiaki_discovery_host_system_version_target(source);
	}

	discovery->callback(result, count, discovery->context);
	free(result);
}

static void tp_play_registration_callback(ChiakiRegistEvent *event, void *context)
{
	TPPlayRegistration *registration = context;
	TPPlayRegisteredHost result;
	TPPlayRegisteredHost *result_pointer = NULL;
	memset(&result, 0, sizeof(result));

	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
	{
		ChiakiRegisteredHost *source = event->registered_host;
		result.target = (int)source->target;
		result.nickname = source->server_nickname;
		result.server_mac = source->server_mac;
		result.server_mac_size = sizeof(source->server_mac);
		result.registration_key = (const uint8_t *)source->rp_regist_key;
		result.registration_key_size = sizeof(source->rp_regist_key);
		result.key_type = source->rp_key_type;
		result.key = source->rp_key;
		result.key_size = sizeof(source->rp_key);
		result.console_pin = source->console_pin;
		result_pointer = &result;
	}

	registration->callback((TPPlayRegistrationEvent)event->type, result_pointer, registration->context);
}

static void tp_play_session_event_callback(ChiakiEvent *event, void *context)
{
	TPPlaySession *session = context;
	int value = 0;
	const char *message = NULL;
	if(event->type == CHIAKI_EVENT_QUIT)
	{
		value = (int)event->quit.reason;
		message = event->quit.reason_str;
	}
	else if(event->type == CHIAKI_EVENT_LOGIN_PIN_REQUEST)
		value = event->login_pin_request.pin_incorrect ? 1 : 0;
	session->event_callback((int)event->type, value, message, session->context);
}

static void tp_play_session_log_callback(ChiakiLogLevel level, const char *message, void *context)
{
	TPPlaySession *session = context;
	chiaki_log_cb_print(level, message, NULL);
	if(!session || !session->event_callback || !message)
		return;

	int stage = 0;
	if(strstr(message, "Starting session request") || strstr(message, "Trying to request session") || strstr(message, "Connected to"))
		stage = TP_PLAY_CONNECTION_STAGE_CONTACTING;
	else if(strstr(message, "Sending session request"))
		stage = TP_PLAY_CONNECTION_STAGE_AUTHENTICATING;
	else if(strstr(message, "Session request successful") || strstr(message, "Starting ctrl") || strstr(message, "Starting Senkusha"))
		stage = TP_PLAY_CONNECTION_STAGE_ESTABLISHING_STREAM;
	else if(strstr(message, "StreamConnection sending big") || strstr(message, "successfully received bang") || strstr(message, "successfully received streaminfo"))
		stage = TP_PLAY_CONNECTION_STAGE_WAITING_FOR_VIDEO;

	if(stage != 0)
		session->event_callback(TP_PLAY_SESSION_EVENT_CONNECTION_STAGE, stage, NULL, session->context);
}

static bool tp_play_session_video_callback(uint8_t *bytes, size_t count, int32_t frames_lost, bool frame_recovered, void *context)
{
	(void)frames_lost;
	(void)frame_recovered;
	TPPlaySession *session = context;
	uint64_t sample_number = atomic_fetch_add(&session->video_sample_count, 1) + 1;
	if(!atomic_exchange(&session->logged_first_video_sample, true) || sample_number % 60 == 0)
		fprintf(stderr, "[TPPLAY-DIAG] encoded video sample #%llu: %zu bytes, lost=%d recovered=%d\n",
			(unsigned long long)sample_number, count, frames_lost, frame_recovered ? 1 : 0);
	return session->video_callback(bytes, count, session->context);
}

static void tp_play_session_audio_settings_callback(uint32_t channels, uint32_t rate, void *context)
{
	TPPlaySession *session = context;
	if(!atomic_exchange(&session->logged_audio_settings, true))
		fprintf(stderr, "[TPPLAY-DIAG] audio configured: %u channels @ %u Hz\n", channels, rate);
	session->audio_settings_callback(channels, rate, session->context);
}

static void tp_play_session_audio_frame_callback(int16_t *samples, size_t sample_count, void *context)
{
	TPPlaySession *session = context;
	/* opus_decode() returns frames per channel, while TPPlayAudioFrameCallback
	 * consumes the total number of interleaved int16 samples. */
	size_t interleaved_sample_count = sample_count * session->audio_decoder.audio_header.channels;
	if(!atomic_exchange(&session->logged_first_audio_frame, true))
		fprintf(stderr, "[TPPLAY-DIAG] first decoded audio frame: %zu interleaved samples\n", interleaved_sample_count);
	session->audio_frame_callback(samples, interleaved_sample_count, session->context);
}

const char *tp_play_core_version(void)
{
	return "1.10.0";
}

TPPlayDiscovery *tp_play_discovery_create(TPPlayDiscoveryCallback callback, void *context, int *error_code)
{
	if(error_code)
		*error_code = CHIAKI_ERR_SUCCESS;
	if(!callback)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}

	pthread_once(&tp_play_core_once, tp_play_initialize_core);
	if(tp_play_core_init_error != CHIAKI_ERR_SUCCESS)
	{
		if(error_code)
			*error_code = tp_play_core_init_error;
		return NULL;
	}

	TPPlayDiscovery *discovery = calloc(1, sizeof(*discovery));
	if(!discovery)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_MEMORY;
		return NULL;
	}

	discovery->callback = callback;
	discovery->context = context;
	chiaki_log_init(&discovery->log, CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, chiaki_log_cb_print, NULL);

	struct sockaddr_in send_address;
	memset(&send_address, 0, sizeof(send_address));
	send_address.sin_len = sizeof(send_address);
	send_address.sin_family = AF_INET;
	send_address.sin_addr.s_addr = htonl(INADDR_BROADCAST);

	ChiakiDiscoveryServiceOptions options;
	memset(&options, 0, sizeof(options));
	options.hosts_max = 16;
	options.host_drop_pings = 3;
	options.ping_ms = 1000;
	options.ping_initial_ms = 0;
	options.send_addr = (struct sockaddr_storage *)&send_address;
	options.send_addr_size = sizeof(send_address);
	options.cb = tp_play_discovery_callback;
	options.cb_user = discovery;

	ChiakiErrorCode error = chiaki_discovery_service_init(&discovery->service, &options, &discovery->log);
	if(error != CHIAKI_ERR_SUCCESS)
	{
		if(error_code)
			*error_code = error;
		free(discovery);
		return NULL;
	}

	return discovery;
}

void tp_play_discovery_destroy(TPPlayDiscovery *discovery)
{
	if(!discovery)
		return;
	chiaki_discovery_service_fini(&discovery->service);
	free(discovery);
}

TPPlayHostState tp_play_console_probe_state(const char *host, bool ps5, uint32_t timeout_ms)
{
	if(!host)
		return TP_PLAY_HOST_STATE_UNKNOWN;
	pthread_once(&tp_play_core_once, tp_play_initialize_core);
	if(tp_play_core_init_error != CHIAKI_ERR_SUCCESS)
		return TP_PLAY_HOST_STATE_UNKNOWN;

	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = strchr(host, ':') ? AF_INET6 : AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	struct addrinfo *addresses = NULL;
	if(getaddrinfo(host, NULL, &hints, &addresses) != 0)
		return TP_PLAY_HOST_STATE_UNKNOWN;

	struct sockaddr_storage destination;
	memset(&destination, 0, sizeof(destination));
	socklen_t destination_size = 0;
	for(struct addrinfo *address = addresses; address; address = address->ai_next)
	{
		if(address->ai_addrlen > sizeof(destination))
			continue;
		memcpy(&destination, address->ai_addr, address->ai_addrlen);
		destination_size = (socklen_t)address->ai_addrlen;
		break;
	}
	freeaddrinfo(addresses);
	if(destination_size == 0)
		return TP_PLAY_HOST_STATE_UNKNOWN;

	if(destination.ss_family == AF_INET)
		((struct sockaddr_in *)&destination)->sin_port = htons(ps5 ? CHIAKI_DISCOVERY_PORT_PS5 : CHIAKI_DISCOVERY_PORT_PS4);
	else
		((struct sockaddr_in6 *)&destination)->sin6_port = htons(ps5 ? CHIAKI_DISCOVERY_PORT_PS5 : CHIAKI_DISCOVERY_PORT_PS4);

	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, chiaki_log_cb_print, NULL);
	ChiakiDiscovery probe;
	if(chiaki_discovery_init(&probe, &log, destination.ss_family) != CHIAKI_ERR_SUCCESS)
		return TP_PLAY_HOST_STATE_UNKNOWN;

	ChiakiDiscoveryPacket packet;
	memset(&packet, 0, sizeof(packet));
	packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
	packet.protocol_version = ps5 ? CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5 : CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;
	if(chiaki_discovery_send(&probe, &packet, (struct sockaddr *)&destination, destination_size) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&probe);
		return TP_PLAY_HOST_STATE_UNKNOWN;
	}

	fd_set read_set;
	FD_ZERO(&read_set);
	FD_SET(probe.socket, &read_set);
	struct timeval timeout = {
		.tv_sec = timeout_ms / 1000,
		.tv_usec = (timeout_ms % 1000) * 1000,
	};
	int selected = select(probe.socket + 1, &read_set, NULL, NULL, &timeout);
	TPPlayHostState state = TP_PLAY_HOST_STATE_UNKNOWN;
	if(selected > 0 && FD_ISSET(probe.socket, &read_set))
	{
		char response[512];
		ssize_t count = recvfrom(probe.socket, response, sizeof(response) - 1, 0, NULL, NULL);
		if(count > 0)
		{
			response[count] = '\0';
			if(strncmp(response, "HTTP/1.1 200", 12) == 0)
				state = TP_PLAY_HOST_STATE_READY;
			else if(strncmp(response, "HTTP/1.1 620", 12) == 0)
				state = TP_PLAY_HOST_STATE_STANDBY;
		}
	}
	chiaki_discovery_fini(&probe);
	return state;
}

int tp_play_console_wake(const char *host, uint64_t credential, bool ps5)
{
	if(!host)
		return CHIAKI_ERR_INVALID_DATA;
	pthread_once(&tp_play_core_once, tp_play_initialize_core);
	if(tp_play_core_init_error != CHIAKI_ERR_SUCCESS)
		return tp_play_core_init_error;
	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, chiaki_log_cb_print, NULL);
	return chiaki_discovery_wakeup(&log, NULL, host, credential, ps5);
}

TPPlayRegistration *tp_play_registration_create(
	int target,
	const char *host,
	bool broadcast,
	const char *psn_online_id,
	const uint8_t *psn_account_id,
	size_t psn_account_id_size,
	uint32_t pin,
	TPPlayRegistrationCallback callback,
	void *context,
	int *error_code)
{
	if(error_code)
		*error_code = CHIAKI_ERR_SUCCESS;
	if(!host || !callback || (!psn_online_id && (!psn_account_id || psn_account_id_size != CHIAKI_PSN_ACCOUNT_ID_SIZE)))
	{
		if(error_code)
			*error_code = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	pthread_once(&tp_play_core_once, tp_play_initialize_core);
	if(tp_play_core_init_error != CHIAKI_ERR_SUCCESS)
	{
		if(error_code)
			*error_code = tp_play_core_init_error;
		return NULL;
	}

	TPPlayRegistration *registration = calloc(1, sizeof(*registration));
	if(!registration)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_MEMORY;
		return NULL;
	}

	registration->callback = callback;
	registration->context = context;
	chiaki_log_init(&registration->log, CHIAKI_LOG_ALL, chiaki_log_cb_print, NULL);

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = (ChiakiTarget)target;
	info.host = host;
	info.broadcast = broadcast;
	info.psn_online_id = psn_online_id;
	if(psn_account_id)
		memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;

	ChiakiErrorCode error = chiaki_regist_start(&registration->regist, &registration->log, &info, tp_play_registration_callback, registration);
	if(error != CHIAKI_ERR_SUCCESS)
	{
		if(error_code)
			*error_code = error;
		free(registration);
		return NULL;
	}
	return registration;
}

void tp_play_registration_stop(TPPlayRegistration *registration)
{
	if(registration)
		chiaki_regist_stop(&registration->regist);
}

void tp_play_registration_destroy(TPPlayRegistration *registration)
{
	if(!registration)
		return;
	chiaki_regist_fini(&registration->regist);
	free(registration);
}

static TPPlaySession *tp_play_session_create_common(
	bool ps5,
	const char *host,
	const uint8_t *registration_key,
	size_t registration_key_size,
	const uint8_t *key,
	size_t key_size,
	ChiakiHolepunchSession holepunch_session,
	const uint8_t *psn_account_id,
	size_t psn_account_id_size,
	unsigned int width,
	unsigned int height,
	unsigned int fps,
	unsigned int bitrate,
	int codec,
	TPPlaySessionEventCallback event_callback,
	TPPlayVideoCallback video_callback,
	TPPlayAudioSettingsCallback audio_settings_callback,
	TPPlayAudioFrameCallback audio_frame_callback,
	void *context,
	int *error_code)
{
	if(error_code)
		*error_code = CHIAKI_ERR_SUCCESS;
	if(!host || (!holepunch_session && (!registration_key || registration_key_size != CHIAKI_SESSION_AUTH_SIZE || !key || key_size != 0x10)) ||
		(holepunch_session && (!psn_account_id || psn_account_id_size != CHIAKI_PSN_ACCOUNT_ID_SIZE)) ||
		!event_callback || !video_callback || !audio_settings_callback || !audio_frame_callback)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}

	TPPlaySession *result = calloc(1, sizeof(*result));
	if(!result)
	{
		if(holepunch_session)
			chiaki_holepunch_session_fini(holepunch_session);
		if(error_code)
			*error_code = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	result->event_callback = event_callback;
	result->video_callback = video_callback;
	result->audio_settings_callback = audio_settings_callback;
	result->audio_frame_callback = audio_frame_callback;
	result->context = context;
	chiaki_log_init(&result->log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, tp_play_session_log_callback, result);
	chiaki_opus_decoder_init(&result->audio_decoder, &result->log);
	chiaki_opus_decoder_set_cb(&result->audio_decoder, tp_play_session_audio_settings_callback, tp_play_session_audio_frame_callback, result);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = ps5;
	info.host = host;
	if(registration_key)
		memcpy(info.regist_key, registration_key, sizeof(info.regist_key));
	if(key)
		memcpy(info.morning, key, sizeof(info.morning));
	info.holepunch_session = holepunch_session;
	if(psn_account_id)
		memcpy(info.psn_account_id, psn_account_id, sizeof(info.psn_account_id));
	info.video_profile.width = width;
	info.video_profile.height = height;
	info.video_profile.max_fps = fps;
	info.video_profile.bitrate = bitrate;
	info.video_profile.codec = (ChiakiCodec)codec;
	info.video_profile_auto_downgrade = true;
	info.enable_dualsense = true;
	/* Keep parity overhead bounded on routed/mobile paths. Reporting very high
	 * transient loss can add enough FEC traffic to prolong the congestion. */
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode error = chiaki_session_init(&result->session, &info, &result->log);
	if(error != CHIAKI_ERR_SUCCESS)
	{
		chiaki_opus_decoder_fini(&result->audio_decoder);
		free(result);
		if(error_code)
			*error_code = error;
		return NULL;
	}
	chiaki_session_set_event_cb(&result->session, tp_play_session_event_callback, result);
	chiaki_session_set_video_sample_cb(&result->session, tp_play_session_video_callback, result);
	ChiakiAudioSink audio_sink;
	chiaki_opus_decoder_get_sink(&result->audio_decoder, &audio_sink);
	chiaki_session_set_audio_sink(&result->session, &audio_sink);
	return result;
}

TPPlaySession *tp_play_session_create(
	bool ps5,
	const char *host,
	const uint8_t *registration_key,
	size_t registration_key_size,
	const uint8_t *key,
	size_t key_size,
	unsigned int width,
	unsigned int height,
	unsigned int fps,
	unsigned int bitrate,
	int codec,
	TPPlaySessionEventCallback event_callback,
	TPPlayVideoCallback video_callback,
	TPPlayAudioSettingsCallback audio_settings_callback,
	TPPlayAudioFrameCallback audio_frame_callback,
	void *context,
	int *error_code)
{
	return tp_play_session_create_common(ps5, host, registration_key, registration_key_size, key, key_size,
		NULL, NULL, 0, width, height, fps, bitrate, codec, event_callback, video_callback,
		audio_settings_callback, audio_frame_callback, context, error_code);
}

TPPlayHolepunch *tp_play_holepunch_prepare(
	const char *psn_access_token,
	const uint8_t *console_duid,
	size_t console_duid_size,
	bool ps5,
	int *error_code)
{
	if(error_code)
		*error_code = CHIAKI_ERR_SUCCESS;
	if(!psn_access_token || !console_duid || console_duid_size != 32)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	pthread_once(&tp_play_core_once, tp_play_initialize_core);
	if(tp_play_core_init_error != CHIAKI_ERR_SUCCESS)
	{
		if(error_code)
			*error_code = tp_play_core_init_error;
		return NULL;
	}

	TPPlayHolepunch *result = calloc(1, sizeof(*result));
	if(!result)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	result->log = malloc(sizeof(*result->log));
	if(!result->log)
	{
		free(result);
		if(error_code)
			*error_code = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	chiaki_log_init(result->log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, chiaki_log_cb_print, NULL);
	result->session = chiaki_holepunch_session_init(psn_access_token, result->log);
	if(!result->session)
	{
		free(result->log);
		free(result);
		if(error_code)
			*error_code = CHIAKI_ERR_UNKNOWN;
		return NULL;
	}
	chiaki_holepunch_session_force_port_guessing(result->session, true);
	(void)chiaki_holepunch_upnp_discover(result->session);

	ChiakiErrorCode error = chiaki_holepunch_session_create(result->session);
	if(error == CHIAKI_ERR_SUCCESS)
		error = holepunch_session_create_offer(result->session);
	if(error == CHIAKI_ERR_SUCCESS)
		error = chiaki_holepunch_session_start(result->session, console_duid,
			ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4);
	if(error == CHIAKI_ERR_SUCCESS)
		error = chiaki_holepunch_session_punch_hole(result->session, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
	if(error != CHIAKI_ERR_SUCCESS)
	{
		chiaki_holepunch_session_fini(result->session);
		free(result->log);
		free(result);
		if(error_code)
			*error_code = error;
		return NULL;
	}
	return result;
}

void tp_play_holepunch_destroy(TPPlayHolepunch *holepunch)
{
	if(!holepunch)
		return;
	if(holepunch->session)
		chiaki_holepunch_session_fini(holepunch->session);
	free(holepunch->log);
	free(holepunch);
}

TPPlaySession *tp_play_session_create_remote(
	bool ps5,
	TPPlayHolepunch *holepunch,
	const uint8_t *psn_account_id,
	size_t psn_account_id_size,
	unsigned int width,
	unsigned int height,
	unsigned int fps,
	unsigned int bitrate,
	int codec,
	TPPlaySessionEventCallback event_callback,
	TPPlayVideoCallback video_callback,
	TPPlayAudioSettingsCallback audio_settings_callback,
	TPPlayAudioFrameCallback audio_frame_callback,
	void *context,
	int *error_code)
{
	if(!holepunch || !holepunch->session || !psn_account_id || psn_account_id_size != CHIAKI_PSN_ACCOUNT_ID_SIZE)
	{
		if(error_code)
			*error_code = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	ChiakiHolepunchSession native = holepunch->session;
	ChiakiLog *holepunch_log = holepunch->log;
	holepunch->session = NULL;
	holepunch->log = NULL;
	free(holepunch);
	TPPlaySession *result = tp_play_session_create_common(ps5, "", NULL, 0, NULL, 0, native,
		psn_account_id, psn_account_id_size, width, height, fps, bitrate, codec,
		event_callback, video_callback, audio_settings_callback, audio_frame_callback,
		context, error_code);
	if(result)
		result->holepunch_log = holepunch_log;
	else
		free(holepunch_log);
	return result;
}

int tp_play_session_start(TPPlaySession *session)
{
	if(!session)
		return CHIAKI_ERR_INVALID_DATA;
	ChiakiErrorCode error = chiaki_session_start(&session->session);
	if(error == CHIAKI_ERR_SUCCESS)
		session->started = true;
	return error;
}

void tp_play_session_stop(TPPlaySession *session)
{
	if(session && session->started)
		chiaki_session_stop(&session->session);
}

int tp_play_session_request_idr(TPPlaySession *session)
{
	if(!session || !session->started)
		return CHIAKI_ERR_INVALID_DATA;
	return chiaki_session_request_idr(&session->session);
}

void tp_play_session_destroy(TPPlaySession *session)
{
	if(!session)
		return;
	if(session->started)
	{
		chiaki_session_stop(&session->session);
		chiaki_session_join(&session->session);
	}
	chiaki_session_fini(&session->session);
	chiaki_opus_decoder_fini(&session->audio_decoder);
	free(session->holepunch_log);
	free(session);
}

int tp_play_session_set_controller(TPPlaySession *session, const TPPlayControllerState *state)
{
	if(!session || !state)
		return CHIAKI_ERR_INVALID_DATA;
	ChiakiControllerState controller;
	chiaki_controller_state_set_idle(&controller);
	controller.buttons = state->buttons;
	controller.l2_state = state->l2;
	controller.r2_state = state->r2;
	controller.left_x = state->left_x;
	controller.left_y = state->left_y;
	controller.right_x = state->right_x;
	controller.right_y = state->right_y;
	controller.touches[0].id = state->touch_active ? 0 : -1;
	controller.touches[0].x = state->touch_x;
	controller.touches[0].y = state->touch_y;
	controller.touch_id_next = state->touch_active ? 1 : 0;
	return chiaki_session_set_controller_state(&session->session, &controller);
}

int tp_play_session_set_login_pin(TPPlaySession *session, const char *pin)
{
	if(!session || !pin)
		return CHIAKI_ERR_INVALID_DATA;
	return chiaki_session_set_login_pin(&session->session, (const uint8_t *)pin, strlen(pin));
}
