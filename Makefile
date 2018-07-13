PROJECT = mqttgw
PROJECT_DESCRIPTION = Authentication and authorization plugin for VerneMQ

define PROJECT_ENV
	[
		{vmq_plugin_hooks, [
			{mqttgw, auth_on_register, 5, []},
			{mqttgw, auth_on_publish, 6, []},
			{mqttgw, auth_on_subscribe, 3, []}
		]}
	]
endef

DEPS = \
	vernemq_dev \
	mqttc \
	jsx

dep_vernemq_dev = git https://github.com/erlio/vernemq_dev.git a17b10615a4b17bd7b8a11846c88edc761b4c6a4
dep_mqttc = cp ../mqtt-client-erlang
dep_jsx = git https://github.com/talentdeficit/jsx.git v2.9.0

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
