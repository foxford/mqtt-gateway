PROJECT = mqttgw
PROJECT_DESCRIPTION = Authentication and authorization plugin for VerneMQ

define PROJECT_ENV
	[
		{vmq_plugin_hooks, [
			{mqttgw, auth_on_register, 5, []},
			{mqttgw, auth_on_publish, 6, []},
			{mqttgw, on_deliver, 4, []},
			{mqttgw, auth_on_subscribe, 3, []}
		]}
	]
endef

DEPS = \
	vernemq_dev \
	toml \
	jose

dep_vernemq_dev = git https://github.com/erlio/vernemq_dev.git ac1669f8aff5fa22e36cd389260bbfe255b82ec7
dep_toml = git https://github.com/dozzie/toml.git v0.3.0
dep_jose = git https://github.com/manifest/jose-erlang v0.1.2

DEP_PLUGINS = version.mk
BUILD_DEPS = version.mk
dep_version.mk = git https://github.com/manifest/version.mk.git v0.2.0

TEST_DEPS = proper

SHELL_DEPS = tddreloader
SHELL_OPTS = \
	-eval 'application:ensure_all_started($(PROJECT), permanent)' \
	-s tddreloader start \
	-config rel/sys

include erlang.mk

.PHONY: elvis
elvis:
	./elvis rock -c elvis.config
