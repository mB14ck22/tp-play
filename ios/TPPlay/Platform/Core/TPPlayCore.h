#ifndef TP_PLAY_CORE_H
#define TP_PLAY_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TPPlayDiscovery TPPlayDiscovery;

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
} TPPlayHost;

typedef void (*TPPlayDiscoveryCallback)(const TPPlayHost *hosts, size_t count, void *context);

const char *tp_play_core_version(void);
TPPlayDiscovery *tp_play_discovery_create(TPPlayDiscoveryCallback callback, void *context, int *error_code);
void tp_play_discovery_destroy(TPPlayDiscovery *discovery);

#ifdef __cplusplus
}
#endif

#endif
