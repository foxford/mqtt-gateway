-module(mqttgw_authz).

%% API
-export([
    read_config/1,
    authorize/2
]).

%% Types
-type config() :: map().

-export_types([config/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config(toml:config()) -> disabled | {enabled, config()}.
read_config(_TomlConfig) ->
    Config = #{},
    {enabled, Config}.

-spec authorize(binary(), config()) -> boolean().
authorize(_Audience, _Config) ->
    false.
