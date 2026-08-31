#ifndef TP_PLAY_CORE_H
#define TP_PLAY_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TPPlayDiscovery TPPlayDiscovery;
typedef struct TPPlayRegistration TPPlayRegistration;
typedef struct TPPlaySession TPPlaySession;

typedef enum TPPlayHostState {
	TP_PLAY_HOST_STATE_UNKNOWN = 0,
	TP_PLAY_HOST_STATE_READY = 1,
	TP_PLAY_HOST_STATE_STANDBY = 2,
} TPPlayHostState;

typedef struct TPPlayHost {
	TPPlayHostState state;
	uint16_t request_port;
	const char *address;
	const char *system_version;
	const char *protocol_version;
	const char *name;
	const char *type;
	const char *identifier;
	const char *running_app_title_id;
	const char *running_app_name;
	bool is_ps5;
	int target;
} TPPlayHost;

typedef enum TPPlayRegistrationEvent {
	TP_PLAY_REGISTRATION_CANCELED = 0,
	TP_PLAY_REGISTRATION_FAILED = 1,
	TP_PLAY_REGISTRATION_SUCCEEDED = 2,
} TPPlayRegistrationEvent;

typedef struct TPPlayRegisteredHost {
	int target;
	const char *nickname;
	const uint8_t *server_mac;
	size_t server_mac_size;
	const uint8_t *registration_key;
	size_t registration_key_size;
	uint32_t key_type;
	const uint8_t *key;
	size_t key_size;
	uint32_t console_pin;
} TPPlayRegisteredHost;

typedef void (*TPPlayRegistrationCallback)(TPPlayRegistrationEvent event, const TPPlayRegisteredHost *host, void *context);
typedef void (*TPPlaySessionEventCallback)(int event_type, int value, const char *message, void *context);
typedef bool (*TPPlayVideoCallback)(const uint8_t *bytes, size_t count, void *context);
typedef void (*TPPlayAudioSettingsCallback)(uint32_t channels, uint32_t sample_rate, void *context);
typedef void (*TPPlayAudioFrameCallback)(const int16_t *samples, size_t sample_count, void *context);

typedef struct TPPlayControllerState {
	uint32_t buttons;
	uint8_t l2;
	uint8_t r2;
	int16_t left_x;
	int16_t left_y;
	int16_t right_x;
	int16_t right_y;
} TPPlayControllerState;

typedef void (*TPPlayDiscoveryCallback)(const TPPlayHost *hosts, size_t count, void *context);

const char *tp_play_core_version(void);
TPPlayDiscovery *tp_play_discovery_create(TPPlayDiscoveryCallback callback, void *context, int *error_code);
void tp_play_discovery_destroy(TPPlayDiscovery *discovery);
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
	int *error_code);
void tp_play_registration_stop(TPPlayRegistration *registration);
void tp_play_registration_destroy(TPPlayRegistration *registration);
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
	int *error_code);
int tp_play_session_start(TPPlaySession *session);
void tp_play_session_stop(TPPlaySession *session);
void tp_play_session_destroy(TPPlaySession *session);
int tp_play_session_set_controller(TPPlaySession *session, const TPPlayControllerState *state);
int tp_play_session_set_login_pin(TPPlaySession *session, const char *pin);

#ifdef __cplusplus
}
#endif

#endif
