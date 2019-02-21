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
read_config(TomlConfig) ->
    case toml:get_value(["features"], "authz", TomlConfig) of
        {boolean, false} -> disabled;
        _ ->
            Config =
                toml:folds(
                    ["authn"],
                    fun(_Config, Section, Acc) ->
                        Aud = parse_audience(Section),
                        Type = parse_type(Section, TomlConfig),
                        Trusted = parse_trusted(Section, TomlConfig),
                        Acc#{Aud => #{type => Type, trusted => Trusted}}
                    end,
                    #{},
                    TomlConfig),

            {enabled, Config}
    end.

-spec authorize(binary(), config()) -> boolean().
authorize(_Audience, _Config) ->
    false.

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
        {string, <<"trusted">>} -> trusted;
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
