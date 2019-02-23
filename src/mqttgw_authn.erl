-module(mqttgw_authn).

%% API
-export([
    read_config/0,
    read_config/1,
    authenticate/2,
    format_account_id/1
]).

%% Types
-type config() :: map().
-type account_id() :: #{label := binary(), audience := binary()}.

-export_types([config/1, account_id/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec read_config() -> disabled | {enabled, config()}.
read_config() ->
    case os:getenv("APP_AUTHN_ENABLED", "1") of
        "0" -> disabled;
        _ ->
            Config = read_config(mqttgw_config:read_config()),
            {enabled, Config}
    end.

-spec read_config(toml:config()) -> config().
read_config(TomlConfig) ->
    toml:folds(
        ["authn"],
        fun(_Config, Section, Acc) ->
            Iss = parse_issuer(Section),
            Aud = parse_audience(Section, TomlConfig),
            {Alg, Key} = parse_key(Section, TomlConfig),
            Acc#{Iss => #{audience => Aud, algorithm => Alg, key => Key}}
        end,
        #{},
        TomlConfig).

-spec authenticate(binary(), config()) -> account_id().
authenticate(Token, Config) ->
    #{<<"sub">> := Sub, <<"aud">> := Aud} =
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
            Token),

    #{label => Sub,
      audience => Aud}.

-spec format_account_id(account_id()) -> binary().
format_account_id(AccountId) ->
    #{label := Label,
      audience := Audience} = AccountId,

    <<Label/binary, $., Audience/binary>>.

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
            {error, Reason} -> error({bad_keypath, Path, Reason})
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
