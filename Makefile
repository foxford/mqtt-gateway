PROJECT = mqttgw
PROJECT_DESCRIPTION = Authentication and authorization plugin for VerneMQ

define PROJECT_ENV
	[{vmq_plugin_hooks,
		[	{mqttgw, auth_on_register, 5, []},
			{mqttgw, auth_on_publish, 6, []},
			{mqttgw, auth_on_subscribe, 3, []} ]}]
endef

DEPS = \
	vernemq_dev

dep_vernemq_dev = git git://github.com/erlio/vernemq_dev.git master

DEP_PLUGINS = version.mk
BUILD_DEPS = version.mk
dep_version.mk = git git://github.com/manifest/version.mk.git master

SHELL_DEPS = tddreloader
SHELL_OPTS = \
	-eval 'application:ensure_all_started($(PROJECT), permanent)' \
	-s tddreloader start \
	-config rel/sys

include erlang.mk
