-module(mqttgw_authz).

%% API
-export([
    read_config/0,
    read_config/1,
    authorize/3
]).

%% Types
-type config() :: map().

-export_types([config/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config() -> disabled | {enabled, mqttgw_authn:account_id(), config()}.
read_config() ->
    case os:getenv("APP_AUTHZ_ENABLED", "1") of
        "0" ->
            error_logger:info_msg("[CONFIG] Authz is disabled~n"),
            disabled;
        _ ->
            TomlConfig = mqttgw_config:read_config(),
            Id = mqttgw_id:read_config(TomlConfig),
            Config = read_config(TomlConfig),
            error_logger:info_msg("[CONFIG] Authz is loaded: ~p, ~p~n", [Id, Config]),
            {enabled, Id, Config}
    end.

-spec read_config(toml:config()) ->config().
read_config(TomlConfig) ->
    toml:folds(
        ["authz"],
        fun(_Config, Section, Acc) ->
            Aud = parse_audience(Section),
            Type = parse_type(Section, TomlConfig),
            Trusted = parse_trusted(Section, TomlConfig),
            Acc#{Aud => #{type => Type, trusted => Trusted}}
        end,
        #{},
        TomlConfig).

-spec authorize(binary(), mqttgw_authn:account_id(), config()) -> ok.
authorize(Audience, AccountId, Config) ->
    case maps:find(Audience, Config) of
        {ok, Inner} ->
            #{trusted := Trusted} = Inner,
            #{audience := SAud} = AccountId,
            case gb_sets:is_member(SAud, Trusted) of
                true -> ok;
                _ -> error({nomatch_trusted, SAud})
            end;
        _ ->
            error({missing_authz_config, Audience})
    end.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec parse_audience(toml:section()) -> binary().
parse_audience(["authz", Aud]) when is_list(Aud) ->
    list_to_binary(Aud);
parse_audience(Val) ->
    error({bad_audience, Val}).

-spec parse_type(toml:section(), toml:config()) -> trusted.
parse_type(Section, Config) ->
    case toml:get_value(Section, "type", Config) of
        {string, "trusted"} -> trusted;
        none -> error(missing_type);
        Other -> error({bad_type, Other})
    end.

-spec parse_trusted(toml:section(), toml:config()) -> gb_sets:set().
parse_trusted(Section, Config) ->
    case toml:get_value(Section, "trusted", Config) of
        {array, {string, L}} -> gb_sets:from_list(lists:map(fun list_to_binary/1, L));
        none -> error(missing_trusted);
        Other -> error({bad_trusted, Other})
    end.
