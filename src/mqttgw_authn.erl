-module(mqttgw_authn).

%% API
-export([
    read_config/1,
    verify/2
]).

%% Types
-type config() :: map().
-type claims() :: map().

-export_types([config/1, claims/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config(toml:config()) -> disabled | {enabled, map()}.
read_config(TomlConfig) ->
    case toml:get_value(["authn"], "disabled", TomlConfig) of
        none ->
            Config =
                toml:folds(
                    ["authn"],
                    fun(_Config, Section, Acc) ->
                        Iss = parse_issuer(Section),
                        Aud = parse_audience(Section, TomlConfig),
                        {Alg, Key} = parse_key(Section, TomlConfig),
                        Acc#{Iss => #{audience => Aud, algorithm => Alg, key => Key}}
                    end,
                    #{},
                    TomlConfig),

            {enabled, Config};
        {boolean, true} ->
            disabled
    end.

-spec verify(binary(), config()) -> claims().
verify(Token, Config) ->
    jose_jws_compact:decode_fn(
        fun([ _, #{<<"iss">> := Iss, <<"aud">> := Aud} | _ ], Opts0) ->
            case maps:find(Iss, Config) of
                {ok, #{audience := AudS, algorithm := Alg, key := Key}} ->
                    %% Verifying expiration time of the token
                    Opts1 = Opts0#{verify => [exp]},
                    %% Verifying that audience within token is allowed for the issuer
                    true = gb_sets:is_member(Aud, AudS),
                    {ok, {Alg, Key, Opts1}};
                _ ->
                    {error, {missing_authn_config, Iss}}
            end
        end,
        Token).

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec parse_issuer(toml:section()) -> binary().
parse_issuer(["authn", Iss]) when is_list(Iss) ->
    list_to_binary(Iss);
parse_issuer(Val) ->
    error({bad_issuer, Val}).

-spec parse_algorithm(toml:section(), toml:config()) -> binary().
parse_algorithm(Section, Config) ->
    case toml:get_value(Section, "algorithm", Config) of
        {string, Val} -> list_to_binary(Val);
        none -> error(missing_algorithm);
        Other -> error({bad_algorithm, Other})
    end.

-spec parse_key(toml:section(), toml:config()) -> {binary(), iodata()}.
parse_key(Section, Config) ->
    case toml:get_value(Section, "key", Config) of
        {string, Path} -> parse_keyfile(Path, Section, Config);
        none -> error(missing_key);
        Other -> error({bad_key, Other})
    end.

-spec parse_keyfile(list(), toml:section(), toml:config()) -> {binary(), iodata()}.
parse_keyfile(Path, Section, Config) ->
    Alg = parse_algorithm(Section, Config),
    MaybeEncodedKey =
        case file:read_file(Path) of
            {ok, Val} -> Val;
            {error, Reason} -> error({bad_keypath, Reason})
        end,
    Basename = filename:basename(Path, ".sample"),
    case filename:extension(Basename) of
        ".pem" -> case catch jose_pem:parse_key(MaybeEncodedKey) of
                {Alg, _} =AlgKey ->
                    AlgKey;
                {OtherAlg, _} ->
                    error({nomatch_algorithm, OtherAlg, Alg, Path});
                _ ->
                    error({bad_pem, Path})
            end;
        _ ->
            {Alg, MaybeEncodedKey}
    end.

-spec parse_audience(toml:section(), toml:config()) -> gb_sets:set().
parse_audience(Section, Config) ->
    case toml:get_value(Section, "audience", Config) of
        {array, {string, L}} -> gb_sets:from_list(lists:map(fun list_to_binary/1, L));
        none -> error(missing_audience);
        Other -> error({bad_audience, Other})
    end.
