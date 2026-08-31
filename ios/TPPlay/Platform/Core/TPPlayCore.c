#include "TPPlayCore.h"

#include <arpa/inet.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <chiaki/common.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>

struct TPPlayDiscovery {
	ChiakiDiscoveryService service;
	ChiakiLog log;
	TPPlayDiscoveryCallback callback;
	void *context;
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
	}

	discovery->callback(result, count, discovery->context);
	free(result);
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
