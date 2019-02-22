-module(mqttgw_id).

%% API
-export([
    read_config/1
]).

%% Types
-type id() :: mqttgw_authn:account_id().

-export_types([id/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config(toml:config()) -> id().
read_config(TomlConfig) ->
    #{label => read_label(TomlConfig),
      audience => read_audience(TomlConfig)}.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec read_label(toml:config()) -> binary().
read_label(TomlConfig) ->
    case toml:get_value(["id"], "label", TomlConfig) of
        {string, Val} -> list_to_binary(Val);
        Other -> error({bad_id_label, Other})
    end.

-spec read_audience(toml:config()) -> binary().
read_audience(TomlConfig) ->
    case toml:get_value(["id"], "audience", TomlConfig) of
        {string, Val} -> list_to_binary(Val);
        Other -> error({bad_id_audience, Other})
    end.
