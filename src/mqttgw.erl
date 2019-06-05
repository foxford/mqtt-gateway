-module(mqttgw).

-behaviour(auth_on_register_hook).
-behaviour(auth_on_register_m5_hook).
-behaviour(auth_on_publish_hook).
-behaviour(auth_on_publish_m5_hook).
-behaviour(on_deliver_hook).
-behaviour(on_deliver_m5_hook).
-behaviour(auth_on_subscribe_hook).
-behaviour(auth_on_subscribe_m5_hook).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
    handle_connect/2,
    handle_publish_mqtt3/3,
    handle_publish_mqtt5/4,
    handle_publish_authz/3,
    handle_deliver_mqtt3/2,
    handle_deliver_mqtt5/3,
    handle_subscribe_authz/2
]).

%% Plugin callbacks
-export([
    start/0,
    stop/0,
    auth_on_register/5,
    auth_on_register_m5/6,
    auth_on_publish/6,
    auth_on_publish_m5/7,
    on_deliver/4,
    on_deliver_m5/5,
    auth_on_subscribe/3,
    auth_on_subscribe_m5/4
]).

%% Definitions
-define(APP, ?MODULE).

%% Types
-type connection_mode() :: default | service_payload_only | service | bridge.

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

-record (message, {
    payload          :: binary(),
    properties = #{} :: map()
}).
-type message() :: #message{}.

-type error() :: #{reason_code := atom()}.

%% =============================================================================
%% API: Connect
%% =============================================================================

-spec handle_connect(binary(), binary()) -> ok | {error, error()}.
handle_connect(ClientId, Password) ->
    try validate_client_id(parse_client_id(ClientId)) of
        Val ->
            handle_connect_authn_config(Val, Password)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid client_id = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [ClientId, T, R]),
            {error, #{reason_code => client_identifier_not_valid}}
    end.

-spec handle_connect_authn_config(client_id(), binary()) -> ok | {error, error()}.
handle_connect_authn_config(ClientId, Password) ->
    case mqttgw_state:find(authn) of
        {ok, disabled} ->
            DirtyAccountId =
                #{label => ClientId#client_id.account_label,
                  audience => ClientId#client_id.audience},
            handle_connect_authz_config(ClientId, DirtyAccountId);
        {ok, {enabled, Config}} ->
            handle_connect_authn(ClientId, Password, Config);
        _ ->
            error_logger:warning_msg(
                "Error on connect: authn config isn't found "
                "for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_connect_authn(client_id(), binary(), mqttgw_authn:config()) -> ok | {error, error()}.
handle_connect_authn(ClientId, Password, Config) ->
    DirtyAccountId =
        #{label => ClientId#client_id.account_label,
          audience => ClientId#client_id.audience},
    try mqttgw_authn:authenticate(Password, Config) of
        AccountId when AccountId =:= DirtyAccountId ->
            handle_connect_authz_config(ClientId, AccountId);
        AccountId ->
            error_logger:warning_msg(
                "Error on connect: account_id = '~s' in the password is "
                " different from the account_id = '~s' in the client_id",
                [ mqttgw_authn:format_account_id(AccountId),
                  mqttgw_authn:format_account_id(DirtyAccountId) ]),
            {error, #{reason_code => not_authorized}}
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid password "
                "for the agent = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [agent_id(ClientId), T, R]),
            {error, #{reason_code => bad_username_or_password}}
    end.

-spec handle_connect_authz_config(client_id(), mqttgw_authn:account_id()) -> ok | {error, error()}.
handle_connect_authz_config(ClientId, AccountId) ->
    #client_id{mode=Mode} = ClientId,

    case mqttgw_state:find(authz) of
        {ok, disabled} ->
            handle_connect_success(ClientId);
        {ok, {enabled, Me, Config}} ->
            handle_connect_authz(Mode, ClientId, AccountId, Me, Config);
        _ ->
            error_logger:warning_msg(
                "Error on connect: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_authz(
    connection_mode(), client_id(), mqttgw_authn:account_id(),
    mqttgw_id:id(), mqttgw_authz:config())
    -> ok | {error, error()}.
handle_connect_authz(default, ClientId, _AccountId, _Me, _Config) ->
    handle_connect_success(ClientId);
handle_connect_authz(_Mode, ClientId, AccountId, Me, Config) ->
    #client_id{mode=Mode} = ClientId,

    try mqttgw_authz:authorize(maps:get(audience, Me), AccountId, Config) of
        _ ->
            handle_connect_success(ClientId)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: connecting in mode = '~s' isn't allowed "
                "for the agent = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Mode, agent_id(ClientId), T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_success(client_id()) -> ok | {error, error()}.
handle_connect_success(ClientId) ->
    #client_id{mode=Mode} = ClientId,

    error_logger:info_msg(
        "Agent = '~s' connected: mode = '~s'",
        [agent_id(ClientId), Mode]),
    ok.

%% =============================================================================
%% API: Publish
%% =============================================================================

-spec handle_publish_mqtt3(topic(), binary(), client_id()) -> {ok, list()} | {error, error()}.
handle_publish_mqtt3(Topic, InputPayload, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try handle_message_properties(
        handle_mqtt3_envelope_properties(
            validate_envelope(parse_envelope(Mode, InputPayload))), ClientId) of
        Message ->
            case handle_publish_authz(Topic, Message, ClientId) of
                ok ->
                    Changes = [{payload, envelope(Message)}],
                    {ok, Changes};
                {error, #{reason_code := Reason}} ->
                    {error, Reason}
            end
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: an invalid message = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt5(topic(), binary(), map(), client_id()) -> {ok, map()} | {error, error()}.
handle_publish_mqtt5(Topic, InputPayload, InputProperties, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    InputMessage = #message{payload = InputPayload, properties = InputProperties},
    try handle_message_properties(InputMessage, ClientId) of
        Message ->
            case handle_publish_authz(Topic, Message, ClientId) of
                ok ->
                    %% TODO: don't modify message payload on publish (only properties)
                    %%
                    %% We can't use the following code now
                    %% because currently there is no way to process
                    %% MQTT Properties from within 'on_deliver' hook
                    %% that is triggered for clients connected via MQTT v3.
                    %%
                    %% #message{payload=Payload, properties=Properties} = Message,
                    %% Changes =
                    %%     #{payload => Payload,
                    %%       properties => InputProperties},
                    Changes =
                        #{payload => envelope(Message),
                          properties => InputProperties#{p_user_property => []}},
                    {ok, Changes};
                Error ->
                    Error
            end
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: an invalid message = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, InputProperties, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_authz(topic(), message(), client_id()) -> ok | {error, error()}.
handle_publish_authz(Topic, Message, ClientId) ->
    handle_publish_authz_config(Topic, Message, ClientId).

-spec handle_publish_authz_config(topic(), message(), client_id()) -> ok | {error, error()}.
handle_publish_authz_config(Topic, Message, ClientId) ->
    case mqttgw_state:find(authz) of
        {ok, disabled} ->
            ok;
        {ok, {enabled, _Me, _Config}} ->
            handle_publish_authz_topic(Topic, Message, ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on publish: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_publish_authz_topic(topic(), message(), client_id()) -> ok | {error, error()}.
handle_publish_authz_topic(Topic, _Message, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_topic(Topic, account_id(ClientId), agent_id(ClientId), Mode) of
        _ ->
            ok
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: publishing to the topic = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Topic, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_message_properties(message(), client_id()) -> message().
handle_message_properties(Message, ClientId) ->
    Message#message{
        properties = update_message_properties(Message#message.properties, ClientId)}.

-spec update_message_properties(map(), client_id()) -> map().
update_message_properties(Properties, ClientId) ->
    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = ClientId,

    UserProperties0 = maps:from_list(maps:get(p_user_property, Properties, [])),

    %% Everything is "event" by default
    UserProperties1 =
        case maps:find(<<"type">>, UserProperties0) of
            error -> UserProperties0#{<<"type">> => <<"event">>};
            _     -> UserProperties0
        end,

    %% Override authn properties
    UserProperties2 =
        case Mode of
            bridge ->
                %% We do not override authn properties for 'bridge' mode,
                %% but verify that they are exist
                validate_authn_properties(UserProperties1);
            _ ->
                UserProperties1#{
                    <<"agent_label">> => AgentLabel,
                    <<"account_label">> => AccountLabel,
                    <<"audience">> => Audience}
        end,

    Properties#{p_user_property => maps:to_list(UserProperties2)}.

-spec handle_mqtt3_envelope_properties(message()) -> message().
handle_mqtt3_envelope_properties(Message) ->
    Message#message{
        properties = to_mqtt5_properteies(Message#message.properties, #{})}.

-spec to_mqtt3_envelope_properties(map(), map()) -> map().
to_mqtt3_envelope_properties(Properties, Acc0) ->
    Acc1 =
        case maps:find(p_user_property, Properties) of
            {ok, UserL} -> maps:merge(Acc0, maps:from_list(UserL));
            error -> Acc0
        end,

    Acc2 =
        case maps:find(p_correlation_data, Properties) of
            {ok, CorrelationData} -> Acc1#{<<"correlation_data">> => CorrelationData};
            error -> Acc1
        end,

    Acc3 =
        case maps:find(p_response_topic, Properties) of
            {ok, ResponseTopic} -> Acc2#{<<"response_topic">> => ResponseTopic};
            error -> Acc2
        end,

    Acc3.

-spec to_mqtt5_properteies(map(), map()) -> map().
to_mqtt5_properteies(Rest0, Acc0) ->
    {Rest1, Acc1} =
        case maps:take(<<"response_topic">>, Rest0) of
            {ResponseTopic, M1} -> {M1, Acc0#{p_response_topic => ResponseTopic}};
            error -> {Rest0, Acc0}
        end,

    {Rest2, Acc2} =
        case maps:take(<<"correlation_data">>, Rest1) of
            {CorrelationData, M2} -> {M2, Acc1#{p_correlation_data => CorrelationData}};
            error -> {Rest1, Acc1}
        end,

    Acc2#{
        p_user_property =>
            maps:to_list(
                maps:merge(
                    maps:get(p_user_property, Acc2, #{}),
                    Rest2))}.

-spec verify_publish_topic(topic(), binary(), binary(), connection_mode()) -> ok.
%% Broadcast:
%% -> event(app-to-any): apps/ACCOUNT_ID(ME)/api/v1/BROADCAST_URI
verify_publish_topic([<<"apps">>, Me, <<"api">>, _ | _], Me, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% -> request(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
verify_publish_topic([<<"agents">>, Me, <<"api">>, _, <<"out">>, _], _AccountId, Me, _Mode)
    -> ok;
%% Unicast:
%% -> request(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
%% -> response(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
verify_publish_topic([<<"agents">>, _, <<"api">>, _, <<"in">>, Me], Me, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Forbidding publishing to any other topics
verify_publish_topic(Topic, _AccountId, AgentId, Mode)
    -> error({nomatch_publish_topic, Topic, AgentId, Mode}).

%% =============================================================================
%% API: Deliver
%% =============================================================================

-spec handle_deliver_mqtt3(binary(), client_id()) -> ok | {ok, list()} | {error, error()}.
handle_deliver_mqtt3(InputPayload, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try handle_mqtt3_envelope_properties(
            validate_envelope(parse_envelope(default, InputPayload))) of
        InputMessage ->
            handle_deliver_mqtt3_changes(Mode, InputMessage)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid message = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_deliver_mqtt3_changes(connection_mode(), message()) -> ok | {ok, list()}.
handle_deliver_mqtt3_changes(service_payload_only, Message) ->
    #message{payload = Payload} = Message,
    {ok, [{payload, Payload}]};
handle_deliver_mqtt3_changes(_Mode, Message) ->
    {ok, [{payload, envelope(Message)}]}.

-spec handle_deliver_mqtt5(binary(), map(), client_id()) -> ok | {ok, map()} | {error, error()}.
handle_deliver_mqtt5(InputPayload, _InputProperties, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    %% TODO: don't modify message payload on publish (only properties)
    % InputMessage = #message{payload = InputPayload, properties = InputProperties},
    % handle_deliver_mqtt5_changes(Mode, InputMessage).

    try handle_mqtt3_envelope_properties(
            validate_envelope(parse_envelope(default, InputPayload))) of
        InputMessage ->
            handle_deliver_mqtt5_changes(Mode, InputMessage)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid message = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_deliver_mqtt5_changes(connection_mode(), message()) -> ok | {ok, map()}.
handle_deliver_mqtt5_changes(_Mode, Message) ->
    #message{payload=Payload, properties=Properties} = Message,
    Changes =
        #{payload => Payload,
          properties => Properties},
    {ok, Changes}.

%% =============================================================================
%% API: Subscribe
%% =============================================================================

-spec handle_subscribe_authz([subscription()], client_id()) ->ok | {error, error()}.
handle_subscribe_authz(Subscriptions, ClientId) ->
    handle_subscribe_authz_config(Subscriptions, ClientId).

-spec handle_subscribe_authz_config([subscription()], client_id()) ->ok | {error, error()}.
handle_subscribe_authz_config(Subscriptions, ClientId) ->
    case mqttgw_state:find(authz) of
        {ok, disabled} ->
            handle_subscribe_success(Subscriptions, ClientId);
        {ok, {enabled, _Me, _Config}} ->
            handle_subscribe_authz_topic(Subscriptions, ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on subscribe: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, not_authorized}
    end.

-spec handle_subscribe_authz_topic([subscription()], client_id()) ->ok | {error, error()}.
handle_subscribe_authz_topic(Subscriptions, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try [verify_subscribtion(Topic, account_id(ClientId), agent_id(ClientId), Mode)
         || {Topic, _QoS} <- Subscriptions] of
        _ ->
            handle_subscribe_success(Subscriptions, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on subscribe: one of the subscriptions = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Subscriptions, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_subscribe_success([subscription()], client_id()) ->ok | {error, error()}.
handle_subscribe_success(Topics, ClientId) ->
    #client_id{mode=Mode} =ClientId,

    error_logger:info_msg(
        "Agent = '~s' subscribed: mode = '~s', topics = ~p",
        [agent_id(ClientId), Mode, Topics]),

    ok.

-spec verify_subscribtion(topic(), binary(), binary(), connection_mode()) -> ok.
verify_subscribtion([<<"$share">>, _Group | Topic], AccountId, AgentId, Mode) ->
    verify_subscribe_topic(Topic, AccountId, AgentId, Mode);
verify_subscribtion(Topic, AccountId, AgentId, Mode) ->
    verify_subscribe_topic(Topic, AccountId, AgentId, Mode).

-spec verify_subscribe_topic(topic(), binary(), binary(), connection_mode()) -> ok.
%% Broadcast:
%% <- event(any-from-app): apps/ACCOUNT_ID/api/v1/BROADCAST_URI
verify_subscribe_topic([<<"apps">>, _, <<"api">>, _ | _], _AccountId, _AgentId, _Mode)
    %% TODO: in 'default' mode the app should be asked for permissions
    %% when (Mode =:= service_payload_only) or (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% <- request(app-from-any): agents/+/api/v1/out/ACCOUNT_ID(ME)
verify_subscribe_topic([<<"agents">>, _, <<"api">>, _, <<"out">>, Me], Me, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service) or (Mode =:= bridge)
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
%% Plugin Callbacks
%% =============================================================================

-spec start() -> ok.
start() ->
    {ok, _} = application:ensure_all_started(?APP),
    mqttgw_state:put(authn, mqttgw_authn:read_config()),
    mqttgw_state:put(authz, mqttgw_authz:read_config()),
    ok.

-spec stop() -> ok.
stop() ->
    ok.

auth_on_register(
    _Peer, {_MountPoint, ClientId} = _SubscriberId, _Username,
    Password, _CleanSession) ->
    case handle_connect(ClientId, Password) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_register_m5(
    _Peer, {_MountPoint, ClientId} = _SubscriberId, _Username,
    Password, _CleanSession, _Properties) ->
    handle_connect(ClientId, Password).

auth_on_publish(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _QoS, Topic, Payload, _IsRetain) ->
    handle_publish_mqtt3(Topic, Payload, parse_client_id(ClientId)).

auth_on_publish_m5(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _QoS, Topic, Payload, _IsRetain, Properties) ->
    handle_publish_mqtt5(Topic, Payload, Properties, parse_client_id(ClientId)).

on_deliver(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _Topic, Payload) ->
    handle_deliver_mqtt3(Payload, parse_client_id(ClientId)).

on_deliver_m5(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _Topic, Payload, Properties) ->
    handle_deliver_mqtt5(Payload, Properties, parse_client_id(ClientId)).

auth_on_subscribe(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Subscriptions) ->
    case handle_subscribe_authz(Subscriptions, parse_client_id(ClientId)) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_subscribe_m5(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Subscriptions, _Properties) ->
    handle_subscribe_authz(Subscriptions, parse_client_id(ClientId)).

%% =============================================================================
%% Internal functions
%% =============================================================================

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

-spec validate_client_id(client_id()) -> client_id().
validate_client_id(Val) ->
    #client_id{
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = Val,

    true = is_binary(AgentLabel),
    true = is_binary(AccountLabel),
    true = is_binary(Audience),

    Val.

-spec parse_client_id(binary()) -> client_id().
parse_client_id(<<"v1/agents/", R/bits>>) ->
    parse_v1_agent_label(R, default, <<>>);
parse_client_id(<<"v1.payload-only/service-agents/", R/bits>>) ->
    parse_v1_agent_label(R, service_payload_only, <<>>);
parse_client_id(<<"v1/service-agents/", R/bits>>) ->
    parse_v1_agent_label(R, service, <<>>);
parse_client_id(<<"v1/bridge-agents/", R/bits>>) ->
    parse_v1_agent_label(R, bridge, <<>>);
parse_client_id(R) ->
    error({bad_mode, [R]}).

-spec parse_v1_agent_label(binary(), connection_mode(), binary())
    -> client_id().
parse_v1_agent_label(<<$., _/bits>>, _Mode, <<>>) ->
    error(missing_agent_label);
parse_v1_agent_label(<<$., R/bits>>, Mode, Acc) ->
    parse_v1_account_label(R, Mode, Acc, <<>>);
parse_v1_agent_label(<<C, R/bits>>, Mode, Acc) ->
    parse_v1_agent_label(R, Mode, <<Acc/binary, C>>);
parse_v1_agent_label(<<>>, Mode, Acc) ->
    error({bad_agent_label, [Mode, Acc]}).

-spec parse_v1_account_label(binary(), connection_mode(), binary(), binary())
    -> client_id().
parse_v1_account_label(<<$., _/bits>>, _Mode, _AgentLabel, <<>>) ->
    error(missing_account_label);
parse_v1_account_label(<<$., R/bits>>,  Mode, AgentLabel, Acc) ->
    parse_v1_audience(R, Mode, AgentLabel, Acc);
parse_v1_account_label(<<C, R/bits>>, Mode, AgentLabel, Acc) ->
    parse_v1_account_label(R, Mode, AgentLabel, <<Acc/binary, C>>);
parse_v1_account_label(<<>>, Mode, AgentLabel, Acc) ->
    error({bad_account_label, [Mode, AgentLabel, Acc]}).

-spec parse_v1_audience(binary(), connection_mode(), binary(), binary())
    -> client_id().
parse_v1_audience(<<>>, _Mode, _AgentLabel, _AccountLabel) ->
    error(missing_audience);
parse_v1_audience(Audience, Mode, AgentLabel, AccountLabel) ->
    #client_id{
        agent_label = AgentLabel,
        account_label = AccountLabel,
        audience = Audience,
        mode = Mode}.

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

-spec validate_envelope(message()) -> message().
validate_envelope(Val) ->
    #message{
        payload=Payload,
        properties=Properties} = Val,

    true = is_binary(Payload),
    true = is_map(Properties),
    Val.

-spec parse_envelope(connection_mode(), binary()) -> message().
parse_envelope(Mode, Message) when (Mode =:= default) or (Mode =:= service) or (Mode =:= bridge) ->
    Envelope = jsx:decode(Message, [return_maps]),
    Payload = maps:get(<<"payload">>, Envelope),
    Properties = maps:get(<<"properties">>, Envelope, #{}),
    #message{payload=Payload, properties=Properties};
parse_envelope(service_payload_only, Message) ->
    #message{payload=Message}.

-spec envelope(message()) -> binary().
envelope(Message) ->
    #message{
        payload=Payload,
        properties=Properties} = Message,

    jsx:encode(
        #{properties => to_mqtt3_envelope_properties(Properties, #{}),
          payload => Payload}).

%% =============================================================================
%% Tests
%% =============================================================================

-ifdef(TEST).

version_mode_t() ->
    ?LET(
        Index,
        choose(1, 4),
        lists:nth(Index,
            [{<<"v1">>, <<"agents">>},
             {<<"v1">>, <<"bridge-agents">>},
             {<<"v1">>, <<"service-agents">>},
             {<<"v1.payload-only">>, <<"service-agents">>}])).

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
            mqttgw_state:put(authz, disabled),
            ok = auth_on_register(Peer, SubscriberId, Username, Password, CleanSession),
            ok = auth_on_register_m5(Peer, SubscriberId, Username, Password, CleanSession, #{}),
            true
        end).

prop_onconnect_invalid_credentials() ->
    ?FORALL(
        {Peer, MountPoint, ClientId, Username, Password, CleanSession},
        {any(), string(), binary(32), binary_utf8_t(), binary_utf8_t(), boolean()},
        begin
            SubscriberId = {MountPoint, ClientId},
            {error, client_identifier_not_valid} =
                auth_on_register(Peer, SubscriberId, Username, Password, CleanSession),
            {error, #{reason_code := client_identifier_not_valid}} =
                auth_on_register_m5(Peer, SubscriberId, Username, Password, CleanSession, #{}),
            true
        end).

authz_onconnect_test_() ->
    AgentLabel = <<"foo">>,
    AccountLabel = <<"bar">>,
    SvcAud = MeAud = <<"svc.example.org">>,
    SvcAccountId = #{label => AccountLabel, audience => SvcAud},
    UsrAud = <<"usr.example.net">>,

    #{password := SvcPassword,
      config := SvcAuthnConfig} =
        make_sample_password(<<"bar">>, SvcAud, <<"svc.example.org">>),
    #{password := UsrPassword,
      config := UsrAuthnConfig} =
        make_sample_password(<<"bar">>, UsrAud, <<"iam.svc.example.net">>),
    #{me := Me,
      config := AuthzConfig} = make_sample_me(MeAud, [SvcAccountId]),

    Test = [
        { "usr: allowed",
          [default], UsrAud, UsrPassword,
          ok },
        { "usr: forbidden",
          [service_payload_only, service, bridge], UsrAud, UsrPassword,
          {error, #{reason_code => not_authorized}} },
        { "svc: allowed",
          [default, service_payload_only, service, bridge], SvcAud, SvcPassword,
          ok }
    ],

    mqttgw_state:new(),
    %% 1 - authn: enabled, authz: disabled
    %% Anyone can connect in any mode when authz is dissabled
    mqttgw_state:put(authn, {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)}),
    mqttgw_state:put(authz, disabled),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(ok, handle_connect(ClientId, Password))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, _Result} <- Test],
    %% 2 - authn: enabled, authz: enabled
    %% User accounts can connect only in 'default' mode
    %% Service accounts can connect in any mode
    mqttgw_state:put(authz, {enabled, Me, AuthzConfig}),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(Result, handle_connect(ClientId, Password))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Result} <- Test],
    %% 3 - authn: disabled, authz: enabled
    mqttgw_state:put(authn, disabled),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(Result, handle_connect(ClientId, Password))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Result} <- Test].

prop_onpublish() ->
    ?FORALL(
        {Username, SubscriberId, QoS, Topic, Payload, IsRetain},
        {binary_utf8_t(), subscriber_id_t(),
         qos_t(), publish_topic_t(), binary_utf8_t(), boolean()},
        begin
            mqttgw_state:new(),
            mqttgw_state:put(authz, disabled),
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            ExpectedAuthnUserL =
                [ {<<"agent_label">>, AgentLabel},
                  {<<"account_label">>, AccountLabel},
                  {<<"audience">>, Audience} ],
            ExpectedAuthnProperties = #{p_user_property => ExpectedAuthnUserL},
            ExpectedUserL = [{<<"type">>, <<"event">>} | ExpectedAuthnUserL],
            ExpectedProperties = #{p_user_property => ExpectedUserL},

            %% MQTT 5
            begin
                {InputPayload, InputProperties} =
                    case Mode of
                        M5 when (M5 =:= default) or (M5 =:= service) ->
                            {Payload, #{}};
                        bridge ->
                            {Payload, ExpectedAuthnProperties};
                        service_payload_only ->
                            {Payload, #{}}
                    end,

                {ok, Modifiers} =
                    auth_on_publish_m5(
                        Username, SubscriberId, QoS,
                        Topic, InputPayload, IsRetain, InputProperties),

                %% TODO: don't modify message payload on publish (only properties)
                %% InputPayload = maps:get(payload, Modifiers),
                %% OutputUserProperties = maps:get(user_property, Modifiers),
                %% lists:usort(OutputUserProperties) == lists:usort(ExpectedUserL)
                ExpectedCompatMessage3 =
                    envelope(#message{payload = Payload, properties = ExpectedProperties}),
                ExpectedCompatMessage3 = maps:get(payload, Modifiers),
                [] = maps:get(p_user_property, maps:get(properties, Modifiers))
            end,

            %% MQTT 3
            begin
                ExpectedMessage3 =
                    envelope(#message{payload = Payload, properties = ExpectedProperties}),
                InputMessage3 =
                    case Mode of
                        M3 when (M3 =:= default) or (M3 =:= service) ->
                            envelope(make_sample_message(Mode, Payload));
                        bridge ->
                            envelope(make_sample_message(Mode, Payload, ExpectedAuthnProperties));
                        service_payload_only ->
                            Payload
                    end,

                {ok, Modifiers3} =
                    auth_on_publish(Username, SubscriberId, QoS, Topic, InputMessage3, IsRetain),
                {_, ExpectedMessage3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

bridge_missing_properties_onpublish_test_() ->
    ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"svc.example.org">>, bridge),
    Test =
        [{"missing properties", #{}},
         {"missing agent_label", #{<<"account_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing account_label", #{<<"agent_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing audience", #{<<"agent_label">> => <<>>, <<"account_label">> => <<>>}}],

    mqttgw_state:new(),
    mqttgw_state:put(authz, disabled),
    [begin
        Message = jsx:encode(#{payload => <<>>, properties => Properties}),
        Expect = {error, #{reason_code => impl_specific_error}},

        [{Desc, ?_assertEqual(Expect, handle_publish_mqtt5([], Message, #{}, ClientId))},
         {Desc, ?_assertEqual(Expect, handle_publish_mqtt3([], Message, ClientId))}]
     end || {Desc, Properties} <- Test].

authz_onpublish_test_() ->
    %% Broadcast:
    %% -> event(app-to-any): apps/ACCOUNT_ID(ME)/api/v1/BROADCAST_URI
    %% Multicast:
    %% -> request(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
    %% Unicast:
    %% -> request(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
    %% -> response(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
    Broadcast = fun(ClientId) ->
        [<<"apps">>, account_id(ClientId), <<"api">>, <<"v1">>, <<>>]
    end,
    Multicast = fun(ClientId) ->
        [<<"agents">>, agent_id(ClientId), <<"api">>, <<"v1">>, <<"out">>, <<>>]
    end,
    Unicast = fun(ClientId) ->
        [<<"agents">>, <<>>, <<"api">>, <<"v1">>, <<"in">>, account_id(ClientId)]
    end,

    Test = [
        {"usr: broadcast", Broadcast, [default], error},
        {"usr: multicast", Multicast, [default], ok},
        {"usr: unicast", Unicast, [default], error},
        {"svc: broadcast", Broadcast, [service_payload_only, service, bridge], ok},
        {"svc: multicast", Multicast, [service_payload_only, service, bridge], ok},
        {"svc: unicast", Unicast, [service_payload_only, service, bridge], ok}
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, {enabled, ignore, ignore}),
    [begin
        [begin
            Message = make_sample_complete_message(Mode),
            ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode),
            Result =
                case handle_publish_authz(TopicFn(ClientId), Message, ClientId) of
                    ok -> ok;
                    {error, _} -> error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, TopicFn, Modes, Expect} <- Test].

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
            InputPayload = jsx:encode(#{payload => Payload, properties => ExpectedProperties}),

            %% MQTT 5
            begin
                InputProperties = #{},

                {ok, Modifiers} =
                    on_deliver_m5(Username, SubscriberId, Topic, InputPayload, InputProperties),
                Payload = maps:get(payload, Modifiers)
            end,

            %% MQTT 3
            begin
                ExpectedPayload3 =
                    case Mode of
                        default              -> InputPayload;
                        bridge               -> InputPayload;
                        service              -> InputPayload;
                        service_payload_only -> Payload
                    end,

                {ok, Modifiers3} =
                    on_deliver(Username, SubscriberId, Topic, InputPayload),
                {_, ExpectedPayload3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

prop_onsubscribe() ->
    mqttgw_state:new(),
    mqttgw_state:put(authz, disabled),
    ?FORALL(
        {Username, SubscriberId, Topics},
        {binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        ok =:= auth_on_subscribe(Username, SubscriberId, Topics)).

authz_onsubscribe_test_() ->
    %% Broadcast:
    %% <- event(any-from-app): apps/ACCOUNT_ID/api/v1/BROADCAST_URI
    %% Multicast:
    %% <- request(app-from-any): agents/+/api/v1/out/ACCOUNT_ID(ME)
    %% Unicast:
    %% <- request(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
    %% <- request(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
    %% <- response(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
    %% <- response(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
    Broadcast = fun(_ClientId) ->
        [<<"apps">>, <<>>, <<"api">>, <<"v1">>, <<>>]
    end,
    Multicast = fun(ClientId) ->
        [<<"agents">>, <<$+>>, <<"api">>, <<"v1">>, <<"out">>, account_id(ClientId)]
    end,
    Unicast = fun(ClientId) ->
        [<<"agents">>, agent_id(ClientId), <<"api">>, <<"v1">>, <<"in">>, <<$+>>]
    end,

    Test = [
        {"usr: broadcast", Broadcast, [default], ok}, %% <- TODO: should be forbidden
        {"usr: multicast", Multicast, [default], {error, #{reason_code => not_authorized}}},
        {"usr: unicast", Unicast, [default], ok},
        {"svc: broadcast", Broadcast, [service_payload_only, service, bridge], ok},
        {"svc: multicast", Multicast, [service_payload_only, service, bridge], ok},
        {"svc: unicast", Unicast, [service_payload_only, service, bridge], ok}
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, {enabled, ignore, ignore}),
    [begin
        [begin
            ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode),
            SubscriptionStd = [{TopicFn(ClientId), 0}],
            SubscriptionShared = [{[<<"$share">>, <<"g">> | TopicFn(ClientId)], 0}],
            ResultStd = handle_subscribe_authz(SubscriptionStd, ClientId),
            ResultShared = handle_subscribe_authz(SubscriptionShared, ClientId),
            [{Desc, ?_assertEqual(Expect, ResultStd)},
             {Desc ++ "– shared", ?_assertEqual(Expect, ResultShared)}]
        end || Mode <- Modes]
    end || {Desc, TopicFn, Modes, Expect} <- Test].

make_sample_password(AccountLabel, Audience, Issuer) ->
    Alg = <<"HS256">>,
    Key = jose_jwa:generate_key(Alg),
    Config =
        #{Issuer =>
          #{algorithm => Alg,
            audience => gb_sets:insert(Audience, gb_sets:new()),
            key => Key}},

    Token =
        jose_jws_compact:encode(
          #{iss => Issuer,
            aud => Audience,
            sub => AccountLabel},
          Alg,
          Key),

    #{password => Token,
      config => Config}.

make_sample_me(MeAud, Trusted) ->
    Me = #{label => <<"mqtt-gateway">>, audience => MeAud},
    Config =
        #{MeAud =>
          #{type => trusted,
            trusted => gb_sets:from_list(Trusted)}},

    #{me => Me,
      config => Config}.

make_sample_client_id(AgentLabel, AccountLabel, Audience, Mode) ->
    #client_id{
        mode = Mode,
        agent_label = AgentLabel,
        account_label = AccountLabel,
        audience = Audience}.

make_sample_connection_client_id(AgentLabel, AccountLabel, Audience, Mode, Version) ->
    AgentId = <<AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>,
    ModeLabel =
        case Mode of
            default -> <<Version/binary, "/agents">>;
            service_payload_only -> <<Version/binary, ".payload-only/service-agents">>;
            service -> <<Version/binary, "/service-agents">>;
            bridge -> <<Version/binary, "/bridge-agents">>
        end,

    <<ModeLabel/binary, $/, AgentId/binary>>.

make_sample_complete_message(Mode) ->
    make_sample_message(
        Mode,
        <<"bar">>,
        #{p_user_property =>
            [ {<<"agent_label">>, <<"test-1">>},
              {<<"account_label">>, <<"john-doe">>},
              {<<"audience">>, <<"example.org">>} ]}).

make_sample_message(Mode, Payload) ->
    make_sample_message(Mode, Payload, #{}).

make_sample_message(Mode, Payload, Properties) ->
    case Mode of
        default ->
            #message{payload = Payload};
        service_payload_only ->
            #message{payload = Payload};
        service ->
            #message{payload = Payload};
        bridge ->
            #message{payload = Payload, properties = Properties};
        _ ->
            error({bad_mode, Mode})
    end.

-endif.
