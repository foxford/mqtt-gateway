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
    case toml:get_value([], "id", TomlConfig) of
        {string, Val} -> mqttgw_authn:parse_account_id(list_to_binary(Val));
        Other -> error({bad_id, Other})
    end.
