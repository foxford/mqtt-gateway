-module(mqttgw_ratelimit).

%% API
-export([
    read_config/0,
    read_config_file/1
]).

%% Types
-type config() :: mqttgw_ratelimitstate:constraints().

%% =============================================================================
%% API
%% =============================================================================

-spec read_config() -> disabled | {enabled, config()}.
read_config() ->
    case os:getenv("APP_RATE_LIMIT_ENABLED", "1") of
        "0" ->
            error_logger:info_msg("[CONFIG] Rate limits are disabled~n"),
            disabled;
        _ ->
            Config = read_config_file(mqttgw_config:read_config_file()),
            error_logger:info_msg("[CONFIG] Rate limits are loaded: ~p~n", [Config]),
            {enabled, Config}
    end.

-spec read_config_file(toml:config()) -> config().
read_config_file(TomlConfig) ->
    #{message_count => parse_message_count(TomlConfig),
      byte_count => parse_byte_count(TomlConfig)}.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec parse_message_count(toml:config()) -> non_neg_integer().
parse_message_count(TomlConfig) ->
    case toml:get_value(["rate_limit"], "message_count", TomlConfig) of
        {integer, Val} -> Val;
        Other -> error({bad_message_count, Other})
    end.

-spec parse_byte_count(toml:config()) -> non_neg_integer().
parse_byte_count(TomlConfig) ->
    case toml:get_value(["rate_limit"], "byte_count", TomlConfig) of
        {integer, Val} -> Val;
        Other -> error({bad_byte_count, Other})
    end.
