-module(mqttgw_id).

%% API
-export([
    read_config/1,
    account_id/1,
    audience/1,
    label/1,
    format_agent_id/1
]).

%% Types
-type agent_id() :: map().

-export_types([agent_id/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config(toml:config()) -> agent_id().
read_config(TomlConfig) ->
    AgentLabel =
        case os:getenv("APP_AGENT_LABEL") of
            false -> parse_agent_label(TomlConfig);
            Val -> Val
        end,

    #{label => AgentLabel,
      account_id => parse_id(TomlConfig)}.

-spec account_id(agent_id()) -> mqttgw_authn:account_id().
account_id(AgentId) ->
    maps:get(account_id, AgentId).

-spec audience(agent_id()) -> binary().
audience(AgentId) ->
    maps:get(audience, maps:get(account_id, AgentId)).

-spec label(agent_id()) -> binary().
label(AgentId) ->
    maps:get(label, AgentId).

-spec format_agent_id(agent_id()) -> binary().
format_agent_id(AgentId) ->
    #{label := Label,
      account_id := AccountId} = AgentId,
    <<Label/binary, $., (mqttgw_authn:format_account_id(AccountId))/binary>>.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec parse_id(toml:config()) -> mqttgw_authn:account_id().
parse_id(TomlConfig) ->
    case toml:get_value([], "id", TomlConfig) of
        {string, Val} -> mqttgw_authn:parse_account_id(list_to_binary(Val));
        Other -> error({bad_id, Other})
    end.

-spec parse_agent_label(toml:config()) -> binary().
parse_agent_label(TomlConfig) ->
    case toml:get_value([], "agent_label", TomlConfig) of
        {string, Val} -> list_to_binary(Val);
        Other -> error({bad_agent_label, Other})
    end.
