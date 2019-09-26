-module(mqttgw_id).

%% API
-export([
    read_config/0,
    read_config_file/1,
    account_id/1,
    account_label/1,
    audience/1,
    label/1,
    format_account_id/1,
    format_agent_id/1
]).

%% Types
-type agent_id() :: #{label := binary(), account_id := mqttgw_authn:account_id()}.

-export_types([agent_id/0]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config() -> agent_id().
read_config() ->
    handle_config_file(error).

-spec read_config_file(toml:config()) -> agent_id().
read_config_file(TomlConfig) ->
    handle_config_file({ok, TomlConfig}).

-spec account_id(agent_id()) -> mqttgw_authn:account_id().
account_id(AgentId) ->
    maps:get(account_id, AgentId).

-spec account_label(agent_id()) -> binary().
account_label(AgentId) ->
    maps:get(label, maps:get(account_id, AgentId)).

-spec audience(agent_id()) -> binary().
audience(AgentId) ->
    maps:get(audience, maps:get(account_id, AgentId)).

-spec label(agent_id()) -> binary().
label(AgentId) ->
    maps:get(label, AgentId).

-spec format_account_id(agent_id()) -> binary().
format_account_id(AgentId) ->
    #{account_id := AccountId} = AgentId,
    mqttgw_authn:format_account_id(AccountId).

-spec format_agent_id(agent_id()) -> binary().
format_agent_id(AgentId) ->
    #{label := Label,
      account_id := AccountId} = AgentId,
    <<Label/binary, $., (mqttgw_authn:format_account_id(AccountId))/binary>>.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec handle_config_file({ok, toml:config()} | error) -> agent_id().
handle_config_file(MaybeTomlConfig) ->
    Config = fun
        ({ok, TomlConfig}) -> TomlConfig;
        (error) -> mqttgw_config:read_config_file()
    end,

    AgentLabel =
        case os:getenv("APP_AGENT_LABEL") of
            false ->
                parse_agent_label(Config(MaybeTomlConfig));
            Val0 ->
                list_to_binary(Val0)
        end,

    AccountId =
        case os:getenv("APP_ACCOUNT_ID") of
            false ->
                parse_id(Config(MaybeTomlConfig));
            Val1 ->
                mqttgw_authn:parse_account_id(list_to_binary(Val1))
        end,

    #{label => AgentLabel,
      account_id => AccountId}.

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
