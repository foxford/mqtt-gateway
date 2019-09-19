-module(mqttgw_config).

%% API
-export([
    read_config_file/0,
    read_config_file/1
]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config_file() -> toml:config().
read_config_file() ->
    case os:getenv("APP_CONFIG") of
        false -> exit(missing_config_path);
        Path  -> read_config_file(Path)
    end.

-spec read_config_file(list()) -> toml:config().
read_config_file(Path) ->
    case toml:read_file(Path) of
        {ok, Config} -> Config;
        {error, Reason} -> exit({invalid_config_path, Reason})
    end.
