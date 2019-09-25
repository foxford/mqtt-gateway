-module(mqttgw_stat).

%% API
-export([
    read_config/0
]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config() -> disabled | {enabled, mqttgw_authn:account_id()}.
read_config() ->
    case os:getenv("APP_STAT_ENABLED", "1") of
        "0" ->
            error_logger:info_msg("[CONFIG] Stat is disabled~n"),
            disabled;
        _ ->
            TomlConfig = mqttgw_config:read_config_file(),
            Id = mqttgw_id:read_config_file(TomlConfig),
            {enabled, Id}
    end.