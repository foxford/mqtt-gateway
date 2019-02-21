-module(mqttgw).

-behaviour(auth_on_register_hook).
-behaviour(auth_on_publish_hook).
-behaviour(on_deliver_hook).
-behaviour(auth_on_subscribe_hook).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
    handle_connect/2,
    handle_publish/3,
    handle_deliver/3,
    handle_subscribe/2
]).

%% Plugin callbacks
-export([
    start/0,
    stop/0,
    auth_on_register/5,
    auth_on_publish/6,
    on_deliver/4,
    auth_on_subscribe/3
]).

%% Definitions
-define(APP, ?MODULE).

%% Types
-type connection_mode() :: default | payload_only | service | bridge.

-record(client_id, {
    mode          :: connection_mode(),
    agent_label   :: binary(),
    account_label :: binary(),
    audience      :: binary()
}).
-type client_id() :: #client_id{}.

-type qos() :: 1..3.
-type topic() :: [binary()].
-type subscription() :: {topic(), qos()}.

-record (envelope, {
    payload    :: binary(),
    properties :: map()
}).
-type envelope() :: #envelope{}.

%% =============================================================================
%% API: Connect
%% =============================================================================

-spec handle_connect(binary(), binary()) -> ok | {error, any()}.
handle_connect(ClientId, Password) ->
    case mqttgw_state:find(authn) of
        {ok, disabled} ->
            handle_connect_client_id(ClientId, ignore);
        {ok, {enabled, Config}} ->
            handle_connect_password(ClientId, Password, Config);
        _ ->
            error_logger:warning_msg(
                "Error on connect: authn config isn't found, client_id=~p",
                [ClientId]),
            {error, impl_specific_error}
    end.

-spec handle_connect_password(binary(), binary(), mqttgw_authn:config()) -> ok | {error, any()}.
handle_connect_password(ClientId, Password, Config) ->
    try mqttgw_authn:verify(Password, Config) of
        Claims ->
            handle_connect_client_id(ClientId, Claims)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid password, client_id=~p, "
                "exception_type=~p, exception_reason=~p",
                [ClientId, T, R]),
            {error, bad_username_or_password}
    end.

-spec handle_connect_client_id(binary(), mqttgw_authn:claims() | ignore) -> ok | {error, any()}.
handle_connect_client_id(ClientId, Claims) ->
    try validate_client_id(parse_client_id(ClientId), Claims) of
        Val ->
            handle_connect_success(Val)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid client_id=~p, "
                "exception_type=~p, exception_reason=~p",
                [ClientId, T, R]),
            {error, client_identifier_not_valid}
    end.

-spec handle_connect_success(client_id()) -> ok | {error, any()}.
handle_connect_success(ClientId) ->
    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = ClientId,

    error_logger:info_msg(
        "Agent connected: mode=~p, agent_label=~s, account_label=~s, audience=~s",
        [Mode, AgentLabel, AccountLabel, Audience]),
    ok.

%% =============================================================================
%% API: Publish
%% =============================================================================

-spec handle_publish(topic(), binary(), client_id()) -> {ok, list()} | {error, any()}.
handle_publish(Topic, Payload, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_topic(Topic, account_id(ClientId), agent_id(ClientId), Mode) of
        _ ->
            handle_publish_envelope(Topic, Payload, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: an invalid topic=~p for the mode=~p, "
                "exception_type=~p, exception_reason=~p",
                [Topic, Mode, T, R]),
            {error, not_authorized}
    end.

-spec handle_publish_envelope(topic(), binary(), client_id()) -> {ok, list()} | {error, any()}.
handle_publish_envelope(_Topic, Payload, ClientId) ->
    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = ClientId,

    try envelope(
            Mode, AgentLabel, AccountLabel, Audience,
            validate_envelope(parse_envelope(Mode, Payload))) of
        UpdatedPayload ->
            {ok, [{payload, UpdatedPayload}]}
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: an invalid msg=~p, "
                "exception_type=~p, exception_reason=~p",
                [Payload, T, R]),
            {error, bad_message}
    end.

-spec verify_publish_topic(topic(), binary(), binary(), connection_mode()) -> ok.
%% Broadcast:
%% -> event(app-to-any): apps/ACCOUNT_ID(ME)/api/v1/BROADCAST_URI
verify_publish_topic([<<"apps">>, Me, <<"api">>, _ | _], Me, _AgentId, Mode)
    when (Mode =:= payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% -> request(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
verify_publish_topic([<<"agents">>, Me, <<"api">>, _, <<"out">>, _], _AccountId, Me, _Mode)
    -> ok;
%% Unicast:
%% -> request(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
%% -> response(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
verify_publish_topic([<<"agents">>, _, <<"api">>, _, <<"in">>, Me], _AccountId, Me, Mode)
    when (Mode =:= payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Forbidding publishing to any other topics
verify_publish_topic(Topic, _AccountId, AgentId, Mode)
    -> error({nomatch_publish_topic, Topic, AgentId, Mode}).

%% =============================================================================
%% API: Deliver
%% =============================================================================

-spec handle_deliver(topic(), binary(), client_id()) -> {ok, list()} | {error, any()}.
handle_deliver(_Topic, Payload, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try deliver_envelope(Mode, Payload) of
        UpdatedPayload ->
            {ok, [{payload, UpdatedPayload}]}
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid msg=~p, "
                "exception_type=~p, exception_reason=~p",
                [Payload, T, R]),
            {error, bad_message}
    end.

%% =============================================================================
%% API: Subscribe
%% =============================================================================

-spec handle_subscribe([subscription()], client_id()) ->ok | {error, any()}.
handle_subscribe(Topics, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try [verify_subscribe_topic(Topic, account_id(ClientId), agent_id(ClientId), Mode)
         || Topic <- Topics] of
        _ ->
            handle_subscribe_success(Topics, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on subscribe: an invalid topic for the mode=~p, "
                "exception_type=~p, exception_reason=~p",
                [Mode, T, R]),
            {error, not_authorized}
    end.

-spec handle_subscribe_success([subscription()], client_id()) ->ok | {error, any()}.
handle_subscribe_success(Topics, ClientId) ->
    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} =ClientId,

    error_logger:info_msg(
        "Agent subscribed: mode=~p, agent_label=~s, account_label=~s, audience=~s, topics=~p",
        [Mode, AgentLabel, AccountLabel, Audience, Topics]),

    ok.

-spec verify_subscribe_topic(topic(), binary(), binary(), connection_mode()) -> ok.
%% Broadcast:
%% <- event(any-from-app): apps/ACCOUNT_ID/api/v1/BROADCAST_URI
verify_subscribe_topic([<<"apps">>, _, <<"api">>, _ | _], _AccountId, _AgentId, _Mode)
    %% TODO: users have to ask permission to subscribe to app's events
    %% when (Mode =:= payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% <- request(app-from-any): agents/+/api/v1/out/ACCOUNT_ID(ME)
verify_subscribe_topic([<<"agents">>, _, <<"api">>, _, <<"out">>, Me], Me, _AgentId, Mode)
    when (Mode =:= payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Unicast:
%% <- request(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
%% <- request(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
%% <- response(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
%% <- response(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
verify_subscribe_topic([<<"agents">>, Me, <<"api">>, _, <<"in">>, _], _AccountId, Me, _Mode)
    -> ok;
%% Forbidding subscribing to any other topics
verify_subscribe_topic(Topic, _AccountId, AgentId, Mode)
    -> error({nomatch_subscribe_topic, Topic, AgentId, Mode}).

%% =============================================================================
%% Plugin callbacks
%% =============================================================================

-spec start() -> ok.
start() ->
    {ok, _} = application:ensure_all_started(?APP),
    TomlConfig = read_config("APP_CONFIG"),
    mqttgw_state:put(authn, mqttgw_authn:read_config(TomlConfig)),
    ok.

-spec stop() -> ok.
stop() ->
    ok.

auth_on_register(
    _Peer, {_MountPoint, ClientId} = _SubscriberId, _Username,
    Password, _CleanSession) ->
    case handle_connect(ClientId, Password) of
        {error, _} ->
            {error, invalid_credentials};
        Ok ->
            Ok
    end.

auth_on_publish(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _QoS, Topic, Payload, _IsRetain) ->

    handle_publish(Topic, Payload, parse_client_id(ClientId)).

on_deliver(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Topic, Payload) ->

    handle_deliver(Topic, Payload, parse_client_id(ClientId)).

auth_on_subscribe(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Topics) ->

    handle_subscribe(Topics, parse_client_id(ClientId)).

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec read_config(list()) -> toml:config().
read_config(Name) ->
    case os:getenv(Name) of
        false -> exit(missing_config_path);
        Path  -> read_config_file(Path)
    end.

-spec read_config_file(list()) -> toml:config().
read_config_file(Path) ->
    case toml:read_file(Path) of
        {ok, Config} -> Config;
        {error, Reason} -> exit({invalid_config_path, Reason})
    end.

-spec agent_id(client_id()) -> binary().
agent_id(ClientId) ->
    #client_id{agent_label=Label} = ClientId,

    <<Label/binary, $., (account_id(ClientId))/binary>>.

-spec account_id(client_id()) -> binary().
account_id(ClientId) ->
    #client_id{
        account_label=Label,
        audience=Audience} = ClientId,

    <<Label/binary, $., Audience/binary>>.

-spec validate_client_id(client_id(), mqttgw_authn:claims() | ignore) -> client_id().
validate_client_id(Val, Claims) ->
    #client_id{
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = Val,

    true = is_binary(AgentLabel),
    true = is_binary(AccountLabel),
    true = is_binary(Audience),

    case Claims of
        ignore -> Val;
        _ ->
            verify_client_account_label(AccountLabel, Claims),
            verify_client_audience(Audience, Claims),
            Val
    end.

-spec verify_client_account_label(binary(), mqttgw_authn:claims()) -> ok.
verify_client_account_label(V, #{<<"sub">> := V}) -> ok;
verify_client_account_label(C, #{<<"sub">> := T}) -> error({nomatch_agent_label, C, T}).

-spec verify_client_audience(binary(), mqttgw_authn:claims()) -> ok.
verify_client_audience(V, #{<<"aud">> := V}) -> ok;
verify_client_audience(C, #{<<"aud">> := T}) -> error({nomatch_audience, C, T}).

-spec parse_client_id(binary()) -> client_id().
parse_client_id(<<"v1.mqtt3/agents/", R/bits>>) ->
    parse_v1_agent_label(R, default, <<>>);
parse_client_id(<<"v1.mqtt3.payload-only/agents/", R/bits>>) ->
    parse_v1_agent_label(R, payload_only, <<>>);
parse_client_id(<<"v1.mqtt3/bridge-agents/", R/bits>>) ->
    parse_v1_agent_label(R, bridge, <<>>).

-spec parse_v1_agent_label(binary(), connection_mode(), binary()) -> client_id().
parse_v1_agent_label(<<$., _/bits>>, _Mode, <<>>) ->
    error(missing_agent_label);
parse_v1_agent_label(<<$., R/bits>>, Mode, Acc) ->
    parse_v1_account_label(R, Mode, Acc, <<>>);
parse_v1_agent_label(<<C, R/bits>>, Mode, Acc) ->
    parse_v1_agent_label(R, Mode, <<Acc/binary, C>>);
parse_v1_agent_label(<<>>, _Mode, Acc) ->
    error({bad_client_id, [Acc]}).

-spec parse_v1_account_label(binary(), connection_mode(), binary(), binary()) -> client_id().
parse_v1_account_label(<<$., _/bits>>, _Mode, _AgentLabel, <<>>) ->
    error(missing_account_label);
parse_v1_account_label(<<$., R/bits>>, Mode, AgentLabel, Acc) ->
    parse_v1_audience(R, Mode, AgentLabel, Acc);
parse_v1_account_label(<<C, R/bits>>, Mode, AgentLabel, Acc) ->
    parse_v1_account_label(R, Mode, AgentLabel, <<Acc/binary, C>>);
parse_v1_account_label(<<>>, _Mode, AgentLabel, Acc) ->
    error({bad_client_id, [AgentLabel, Acc]}).

-spec parse_v1_audience(binary(), connection_mode(), binary(), binary()) -> client_id().
parse_v1_audience(<<>>, _Mode, _AgentLabel, _AccountLabel) ->
    error(missing_audience);
parse_v1_audience(Audience, Mode, AgentLabel, AccountLabel) ->
    #client_id{agent_label=AgentLabel, account_label=AccountLabel, audience=Audience, mode=Mode}.

-spec validate_authn_properties(map()) -> map().
validate_authn_properties(Properties) ->
    _ = validate_agent_label_property(Properties),
    _ = validate_account_label_property(Properties),
    _ = validate_audience_property(Properties),
    Properties.

-spec validate_agent_label_property(map()) -> binary().
validate_agent_label_property(#{<<"agent_label">> := Val}) when is_binary(Val) ->
    Val;
validate_agent_label_property(#{<<"agent_label">> := Val}) ->
    error({bad_agent_label, Val});
validate_agent_label_property(_) ->
    error(missing_agent_label).

-spec validate_account_label_property(map()) -> binary().
validate_account_label_property(#{<<"account_label">> := Val}) when is_binary(Val) ->
    Val;
validate_account_label_property(#{<<"account_label">> := Val}) ->
    error({bad_account_label, Val});
validate_account_label_property(_) ->
    error(missing_account_label).

-spec validate_audience_property(map()) -> binary().
validate_audience_property(#{<<"audience">> := Val}) when is_binary(Val) ->
    Val;
validate_audience_property(#{<<"audience">> := Val}) ->
    error({bad_audience, Val});
validate_audience_property(_) ->
    error(missing_audience).

-spec validate_envelope(envelope()) -> envelope().
validate_envelope(Val) ->
    #envelope{
        payload=Payload,
        properties=Properties} = Val,

    true = is_binary(Payload),
    true = is_map(Properties),
    Val.

-spec parse_envelope(connection_mode(), binary()) -> envelope().
parse_envelope(Mode, Message) when (Mode =:= default) or (Mode =:= bridge) ->
    Envelope = jsx:decode(Message, [return_maps]),
    Payload = maps:get(<<"payload">>, Envelope),
    Properties = maps:get(<<"properties">>, Envelope, #{}),
    #envelope{payload=Payload, properties=Properties};
parse_envelope(payload_only, Message) ->
    #envelope{payload=Message, properties=#{}}.

-spec envelope(connection_mode(), binary(), binary(), binary(), envelope()) -> binary().
envelope(Mode, AgentLabel, AccountLabel, Audience, Envelope) ->
    #envelope{
        payload=Payload,
        properties=Properties} = Envelope,

    %% Everything is "event" by default
    UpdatedProperties0 =
        case maps:find(<<"type">>, Properties) of
            error -> Properties#{<<"type">> => <<"event">>};
            _     -> Properties
        end,

    %% Override authn properties
    UpdatedProperties1 =
        case Mode of
            bridge ->
                %% We do not override authn properties for 'bridge' mode,
                %% but verify that they are exist
                validate_authn_properties(UpdatedProperties0);
            _ ->
                UpdatedProperties0#{
                    <<"agent_label">> => AgentLabel,
                    <<"account_label">> => AccountLabel,
                    <<"audience">> => Audience}
        end,

    jsx:encode(
        #{properties => UpdatedProperties1,
          payload => Payload}).

-spec deliver_envelope(connection_mode(), binary()) -> binary().
deliver_envelope(Mode, Payload) ->
    Envelope = validate_envelope(parse_envelope(default, Payload)),
    case Mode of
        Mode when (Mode =:= default) or (Mode =:= bridge) ->
            Payload;
        payload_only ->
            #envelope{payload=InnerPayload} = Envelope,
            InnerPayload
    end.

%% =============================================================================
%% Tests
%% =============================================================================

-ifdef(TEST).

version_mode_t() ->
    ?LET(
        Index,
        choose(1, 3),
        lists:nth(Index,
            [{<<"v1.mqtt3">>, <<"bridge-agents">>},
             {<<"v1.mqtt3">>, <<"agents">>},
             {<<"v1.mqtt3.payload-only">>, <<"agents">>}])).

client_id_t() ->
    ?LET(
        {{Version, Mode}, AgentLabel, AccountLabel, Audience},
        {version_mode_t(), label_t(), label_t(), label_t()},
        <<Version/binary, $/, Mode/binary, $/,
          AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>).

subscriber_id_t() ->
    ?LET(
        {MountPoint, ClientId},
        {string(), client_id_t()},
        {MountPoint, ClientId}).

binary_utf8_t() ->
    ?LET(Val, string(), unicode:characters_to_binary(Val, utf8, utf8)).

%% Exclude:
%% - multi-level wildcard '#' = <<35>>
%% - single-level wildcard '+' = <<43>>
%% - single-level separator '/' = <<47>>
%% - symbols: '.' = <<46>>
label_t() ->
    ?LET(
        Val,
        non_empty(list(union([
            integer(0, 34),
            integer(36, 42),
            integer(44, 45),
            integer(48, 16#10ffff)
        ]))),
        unicode:characters_to_binary(Val, utf8, utf8)).

%% Exclude:
%% - multi-level wildcard '#' = <<35>>
%% - single-level wildcard '+' = <<43>>
%% - single-level separator '/' = <<47>>
publish_topic_t() ->
    ?LET(
        Val,
        list(union([
            integer(0, 34),
            integer(36, 42),
            integer(44, 46),
            integer(48, 16#10ffff)
        ])),
        unicode:characters_to_binary(Val, utf8, utf8)).

subscribe_topic_t() ->
    ?LET(Val, binary_utf8_t(), Val).

qos_t() ->
    ?LET(Val, integer(0, 2), Val).

prop_onconnect() ->
    ?FORALL(
        {Peer, SubscriberId, Username, Password, CleanSession},
        {any(), subscriber_id_t(), binary_utf8_t(), binary_utf8_t(), boolean()},
        begin
            mqttgw_state:new(),
            mqttgw_state:put(authn, disabled),
            ok =:= auth_on_register(Peer, SubscriberId, Username, Password, CleanSession)
        end).

prop_onconnect_invalid_credentials() ->
    ?FORALL(
        {Peer, MountPoint, ClientId, Username, Password, CleanSession},
        {any(), string(), binary(32), binary_utf8_t(), binary_utf8_t(), boolean()},
        {error, invalid_credentials} =:=
            auth_on_register(Peer, {MountPoint, ClientId}, Username, Password, CleanSession)).

prop_onpublish() ->
    ?FORALL(
        {Username, SubscriberId, QoS, Topic, Payload, IsRetain},
        {binary_utf8_t(), subscriber_id_t(),
         qos_t(), publish_topic_t(), binary_utf8_t(), boolean()},
        begin
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            ExpectedAuthnProps =
                #{<<"agent_label">> => AgentLabel,
                  <<"account_label">> => AccountLabel,
                  <<"audience">> => Audience},
            ExpectedProperties = ExpectedAuthnProps#{<<"type">> => <<"event">>},
            ExpectedMessage = jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
            InputMessage =
                case Mode of
                    bridge ->
                        jsx:encode(#{payload => Payload, properties => ExpectedAuthnProps});
                    default ->
                        jsx:encode(#{payload => Payload});
                    payload_only ->
                        Payload
                end,

            {ok, Modifiers} =
                auth_on_publish(Username, SubscriberId, QoS, Topic, InputMessage, IsRetain),
            {_, OutputMessage} = lists:keyfind(payload, 1, Modifiers),
            OutputMessage =:= ExpectedMessage
        end).

bridge_missing_properties_test_() ->
    Test =
        [{"missing properties", #{}},
         {"missing agent_label", #{<<"account_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing account_label", #{<<"agent_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing audience", #{<<"agent_label">> => <<>>, <<"account_label">> => <<>>}}],

    ClientId = <<"v1.mqtt3/bridge-agents/x.a.example.org">>,
    [begin
        Message = jsx:encode(#{payload => <<>>, properties => Properties}),
        Error = auth_on_publish(<<>>, {[], ClientId}, 0, [<<>>], Message, false),
        ExpectedError = {error, bad_message},
        {Desc, ?_assertEqual(ExpectedError, Error)}
     end || {Desc, Properties} <- Test].

prop_ondeliver() ->
    ?FORALL(
        {Username, SubscriberId, Topic, Payload},
        {binary_utf8_t(), subscriber_id_t(),
         publish_topic_t(), binary_utf8_t()},
        begin
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            ExpectedProperties =
                #{<<"agent_label">> => AgentLabel,
                  <<"account_label">> => AccountLabel,
                  <<"audience">> => Audience},
            InputMessage = jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
            ExpectedMessage =
                case Mode of
                    bridge       -> InputMessage;
                    default      -> InputMessage;
                    payload_only -> Payload
                end,

            {ok, Modifiers} =
                on_deliver(Username, SubscriberId, Topic, InputMessage),
            {_, OutputMessage} = lists:keyfind(payload, 1, Modifiers),
            OutputMessage =:= ExpectedMessage
        end).

prop_onsubscribe() ->
    ?FORALL(
        {Username, SubscriberId, Topics},
        {binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        ok =:= auth_on_subscribe(Username, SubscriberId, Topics)).

-endif.
