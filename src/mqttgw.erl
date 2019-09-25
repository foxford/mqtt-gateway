-module(mqttgw).

-behaviour(auth_on_register_hook).
-behaviour(auth_on_register_m5_hook).
-behaviour(auth_on_publish_hook).
-behaviour(auth_on_publish_m5_hook).
-behaviour(on_deliver_hook).
-behaviour(on_deliver_m5_hook).
-behaviour(auth_on_subscribe_hook).
-behaviour(auth_on_subscribe_m5_hook).
-behaviour(on_client_offline_hook).
-behaviour(on_client_gone_hook).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
    handle_connect/3,
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
    auth_on_subscribe_m5/4,
    on_client_offline/1,
    on_client_gone/1
]).

%% Definitions
-define(APP, ?MODULE).

%% Types

% Types
-type qos() :: 1..3.
-type topic() :: [binary()].
-type subscription() :: {topic(), qos()}.
-type connection() :: binary().

-type connection_mode() :: default | service_payload_only | service | observer | bridge.

-record(client_id, {
    mode          :: connection_mode(),
    agent_label   :: binary(),
    account_label :: binary(),
    audience      :: binary()
}).
-type client_id() :: #client_id{}.

-record (message, {
    payload          :: binary(),
    properties = #{} :: map()
}).
-type message() :: #message{}.

-type error() :: #{reason_code := atom()}.

-export_types([qos/0, topic/0, subscription/0]).

%% =============================================================================
%% API: Connect
%% =============================================================================

-spec handle_connect(connection(), binary(), boolean()) -> ok | {error, error()}.
handle_connect(Conn, Password, CleanSession) ->
    try validate_client_id(parse_client_id(Conn)) of
        ClientId ->
            handle_connect_constraints(ClientId, Password, CleanSession)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid client_id = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Conn, T, R]),
            {error, #{reason_code => client_identifier_not_valid}}
    end.

-spec handle_connect_constraints(client_id(), binary(), boolean()) -> ok | {error, error()}.
handle_connect_constraints(ClientId, Password, CleanSession) ->
    try verify_connect_constraints(CleanSession, ClientId#client_id.mode) of
        _ ->
            handle_connect_authn_config(ClientId, Password)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: invalid constraints check, clean_session = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [CleanSession, T, R]),
            {error, #{reason_code => impl_specific_error}}
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
            handle_connect_stat_config(ClientId);
        {ok, {enabled, BMe, Config}} ->
            handle_connect_authz(Mode, ClientId, AccountId, broker_client_id(BMe), Config);
        _ ->
            error_logger:warning_msg(
                "Error on connect: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_authz(
    connection_mode(), client_id(), mqttgw_authn:account_id(),
    client_id(), mqttgw_authz:config())
    -> ok | {error, error()}.
handle_connect_authz(default, ClientId, _AccountId, _BrokerId, _Config) ->
    handle_connect_stat_config(ClientId);
handle_connect_authz(_Mode, ClientId, AccountId, BrokerId, Config) ->
    #client_id{mode=Mode} = ClientId,

    try mqttgw_authz:authorize(BrokerId#client_id.audience, AccountId, Config) of
        _ ->
            handle_connect_stat_config(ClientId)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: connecting in mode = '~s' isn't allowed "
                "for the agent = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Mode, agent_id(ClientId), T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_stat_config(client_id()) -> ok | {error, error()}.
handle_connect_stat_config(ClientId) ->
    case mqttgw_state:find(stat) of
        {ok, disabled} ->
            handle_connect_success(ClientId);
        {ok, {enabled, BMe}} ->
            send_audience_event(
                #{id => agent_id(ClientId)},
                <<"agent.enter">>,
                broker_client_id(BMe),
                ClientId),
            handle_connect_success(ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on connect: stat config isn't found "
                "for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_connect_success(client_id()) -> ok | {error, error()}.
handle_connect_success(ClientId) ->
    #client_id{mode=Mode} = ClientId,

    error_logger:info_msg(
        "Agent = '~s' connected: mode = '~s'",
        [agent_id(ClientId), Mode]),
    ok.

-spec verify_connect_constraints(boolean(), connection_mode()) -> ok.
verify_connect_constraints(CleanSession, Mode) ->
    ok = verify_connect_clean_session_constraint(CleanSession, Mode),
    ok.

-spec verify_connect_clean_session_constraint(boolean(), connection_mode()) -> ok.
%% Any for trusted modes
verify_connect_clean_session_constraint(_IsRetain, Mode)
    when (Mode =:= service) or (Mode =:= service_payload_only)
      or (Mode =:= bridge) or (Mode =:= observer)
    -> ok;
%% Only 'false' for anyone else
verify_connect_clean_session_constraint(true, _Mode) ->
    ok;
verify_connect_clean_session_constraint(IsRetain, _Mode) ->
    error({bad_retain, IsRetain}).

%% =============================================================================
%% API: Disconnect
%% =============================================================================

-spec handle_disconnect(connection()) -> ok.
handle_disconnect(Conn) ->
    handle_disconnect_authz_config(Conn, parse_client_id(Conn)).

-spec handle_disconnect_authz_config(connection(), client_id()) -> ok.
handle_disconnect_authz_config(Conn, ClientId) ->
    case mqttgw_state:find(authz) of
        {ok, disabled} ->
            handle_disconnect_stat_config(ClientId);
        {ok, {enabled, BMe, _}} ->
            delete_client_dynsubs(Conn, broker_client_id(BMe)),
            handle_disconnect_stat_config(ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on connect: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_disconnect_stat_config(client_id()) -> ok | {error, error()}.
handle_disconnect_stat_config(ClientId) ->
    case mqttgw_state:find(stat) of
        {ok, disabled} ->
            handle_disconnect_success(ClientId);
        {ok, {enabled, BMe}} ->
            send_audience_event(
                #{id => agent_id(ClientId)},
                <<"agent.leave">>,
                broker_client_id(BMe),
                ClientId),
            handle_disconnect_success(ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on connect: stat config isn't found "
                "for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_disconnect_success(client_id()) -> ok.
handle_disconnect_success(ClientId) ->
    #client_id{mode=Mode} = ClientId,

    error_logger:info_msg(
        "Agent = '~s' disconnected: mode = '~s'",
        [agent_id(ClientId), Mode]),
    ok.

%% =============================================================================
%% API: Publish
%% =============================================================================

-spec handle_publish_mqtt3_constraints(topic(), binary(), qos(), boolean(), client_id())
    -> {ok, list()} | {error, error()}.
handle_publish_mqtt3_constraints(Topic, InputPayload, QoS, IsRetain, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt3(Topic, InputPayload, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt3(topic(), binary(), client_id())
    -> {ok, list()} | {error, error()}.
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

-spec handle_publish_mqtt5_constraints(topic(), binary(), map(), qos(), boolean(), client_id())
    -> {ok, map()} | {error, error()}.
handle_publish_mqtt5_constraints(Topic, InputPayload, InputProperties, QoS, IsRetain, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt5(Topic, InputPayload, InputProperties, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, agent_id(ClientId), Mode, T, R]),
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
        {ok, {enabled, BMe, _Config}} ->
            handle_publish_authz_topic(Topic, Message, broker_client_id(BMe), ClientId);
        _ ->
            error_logger:warning_msg(
                "Error on publish: authz config isn't found for the agent = '~s'",
                [agent_id(ClientId)]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_publish_authz_topic(topic(), message(), client_id(), client_id())
    -> ok | {error, error()}.
handle_publish_authz_topic(Topic, Message, BrokerId, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_topic(Topic, account_id(ClientId), agent_id(ClientId), Mode) of
        _ ->
            handle_publish_authz_broker_request(
                Topic, Message, account_id(BrokerId), BrokerId, ClientId)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: publishing to the topic = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Topic, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_publish_authz_broker_request(
    topic(), message(), binary(), client_id(), client_id())
    -> ok | {error, error()}.
handle_publish_authz_broker_request(
    [<<"agents">>, _, <<"api">>, Version, <<"out">>, BrokerAccoundId],
    #message{payload = Payload, properties = Properties},
    BrokerAccoundId, BrokerId, ClientId) ->
    #client_id{mode=Mode} = ClientId,

    try {Mode, jsx:decode(Payload, [return_maps]), parse_broker_request_properties(Properties)} of
        {service,
         #{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.create">>,
           correlation_data := CorrData,
           response_topic := RespTopic}} ->
               handle_publish_authz_broker_dynsub_create_request(
                   Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId);
        {service,
         #{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.delete">>,
           correlation_data := CorrData,
           response_topic := RespTopic}} ->
               handle_publish_authz_broker_dynsub_delete_request(
                   Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId);
        _ ->
            error_logger:error_msg(
                "Error on publish: unsupported broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', ",
                [Payload, Properties, agent_id(ClientId), Mode]),
            {error, #{reason_code => impl_specific_error}}
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: an invalid broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Payload, Properties, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end;
handle_publish_authz_broker_request(_Topic, _Message, _BrokerAccoundId, _BrokerId, _ClientId) ->
    ok.

-spec handle_publish_authz_broker_dynsub_create_request(
    binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), binary(), client_id(), client_id())
    -> ok | {error, error()}.
handle_publish_authz_broker_dynsub_create_request(
    Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId) ->
    #client_id{
        account_label=AccountLabel,
        audience=Audience} = ClientId,

    %% Subscribe the agent to the app's topic and send a success response
    App = mqttgw_authn:format_account_id(#{label => AccountLabel, audience => Audience}),
    Data = #{app => App, object => Object, version => Version},
    create_dynsub(Subject, Data),

    %% Send an unicast response to the 3rd-party agent
    send_dynsub_response(App, CorrData, RespTopic, BrokerId, ClientId),

    %% Send a multicast event to the application
    send_dynsub_event(<<"subscription.create">>, Subject, Data, BrokerId),
    ok.

-spec handle_publish_authz_broker_dynsub_delete_request(
    binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), binary(), client_id(), client_id())
    -> ok | {error, error()}.
handle_publish_authz_broker_dynsub_delete_request(
    Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId) ->
    #client_id{
        account_label=AccountLabel,
        audience=Audience} = ClientId,

    %% Unsubscribe the agent from the app's topic and send a success response
    App = mqttgw_authn:format_account_id(#{label => AccountLabel, audience => Audience}),
    Data = #{app => App, object => Object, version => Version},
    delete_dynsub(Subject, Data),

    %% Send an unicast response to the 3rd-party agent
    send_dynsub_response(App, CorrData, RespTopic, BrokerId, ClientId),

    %% Send a multicast event to the application
    send_dynsub_event(<<"subscription.delete">>, Subject, Data, BrokerId),
    ok.

-spec handle_message_properties(message(), client_id()) -> message().
handle_message_properties(Message, ClientId) ->
    UpdatedProperties =
        validate_message_properties(
            update_message_properties(Message#message.properties, ClientId), ClientId),

    Message#message{
        properties = UpdatedProperties}.

-spec validate_message_properties(map(), client_id()) -> map().
validate_message_properties(Properties, ClientId) ->
    #client_id{mode=Mode} = ClientId,
    UserProperties = maps:from_list(maps:get(p_user_property, Properties, [])),

    %% Type of the value for user property is always an utf8 string
    IsUtf8String = fun(Val) ->
        is_binary(catch unicode:characters_to_binary(Val, utf8, utf8))
    end,
    IsUtf8Pair = fun({Key, Val}, Acc) ->
        IsUtf8String(Key) andalso IsUtf8String(Val) andalso Acc
    end,
    case lists:foldl(IsUtf8Pair, true, maps:to_list(UserProperties)) of
        false -> error({bad_user_property, Properties});
        _ -> ok
    end,

    %% Required properties for p_user_property(type)=request|response
    case maps:find(<<"type">>, UserProperties) of
        {ok, <<"request">>} ->
            %% Rrequired properties:
            %% - p_user_property(method)
            %% - p_correlation_data
            %% - p_response_topic
            case
                { maps:find(<<"method">>, UserProperties),
                  maps:find(p_correlation_data, Properties),
                  maps:find(p_response_topic, Properties) } of

                {error, _, _} -> error({missing_method_user_property, Properties});
                {_, error, _} -> error({missing_correlation_data_property, Properties});
                {_, _, error} -> error({missing_response_topic_property, Properties});
                %% Only services can specify a response topic that is not assosiated
                %% with their account
                {_, _, {ok,  _}} when Mode =:= service -> ok;
                {_, _, {ok, RT}} ->
                    verify_response_topic(binary:split(RT, <<$/>>, [global]), agent_id(ClientId))
            end;
        {ok, <<"response">>} ->
            %% Rrequired properties:
            %% - p_user_property(status)
            %% - p_correlation_data
            case
                { maps:find(<<"status">>, UserProperties),
                  maps:find(p_correlation_data, Properties) } of

                {error, _} -> error({missing_status_user_property, Properties});
                {_, error} -> error({missing_correlation_data_property, Properties});
                _ -> ok
            end;
        _ ->
            ok
    end,

    Properties.

-spec verify_response_topic(topic(), binary()) -> ok.
verify_response_topic([<<"agents">>, Me, <<"api">>, _, <<"in">>, _], Me) ->
    ok;
verify_response_topic(Topic, AgentId) ->
    error({bad_response_topic, Topic, AgentId}).

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

    %% Additional connection properties
    {VersionStr, ModeStr} = connection_versionmode(Mode),
    UserProperties3 =
        UserProperties2#{
            <<"connection_version">> => VersionStr,
            <<"connection_mode">> => ModeStr},

    Properties#{p_user_property => maps:to_list(UserProperties3)}.

-spec handle_mqtt3_envelope_properties(message()) -> message().
handle_mqtt3_envelope_properties(Message) ->
    Message#message{
        properties = to_mqtt5_properties(Message#message.properties, #{})}.

-spec to_mqtt3_envelope_properties(map(), map()) -> map().
to_mqtt3_envelope_properties(Properties, Acc0) ->
    Acc1 =
        case maps:find(p_user_property, Properties) of
            {ok, UserL} -> maps:merge(Acc0, maps:from_list(UserL));
            error -> Acc0
        end,

    Acc2 =
        case maps:find(p_correlation_data, Properties) of
            {ok, CorrData} -> Acc1#{<<"correlation_data">> => CorrData};
            error -> Acc1
        end,

    Acc3 =
        case maps:find(p_response_topic, Properties) of
            {ok, RespTopic} -> Acc2#{<<"response_topic">> => RespTopic};
            error -> Acc2
        end,

    Acc3.

-spec to_mqtt5_properties(map(), map()) -> map().
to_mqtt5_properties(Rest0, Acc0) ->
    {Rest1, Acc1} =
        case maps:take(<<"response_topic">>, Rest0) of
            {RespTopic, M1} -> {M1, Acc0#{p_response_topic => RespTopic}};
            error -> {Rest0, Acc0}
        end,

    {Rest2, Acc2} =
        case maps:take(<<"correlation_data">>, Rest1) of
            {CorrData, M2} -> {M2, Acc1#{p_correlation_data => CorrData}};
            error -> {Rest1, Acc1}
        end,

    UserProperties =
        maps:to_list(
            maps:merge(
                maps:from_list(maps:get(p_user_property, Acc2, [])),
                Rest2)),
    case length(UserProperties) of
        0 -> Acc2;
        _ -> Acc2#{p_user_property => UserProperties}
    end.

-spec verify_publish_constraints(qos(), boolean(), connection_mode()) -> ok.
verify_publish_constraints(QoS, IsRetain, Mode) ->
    ok = verify_publish_qos_constraint(QoS, Mode),
    ok = verify_publish_retain_constraint(IsRetain, Mode),
    ok.

-spec verify_publish_qos_constraint(qos(), connection_mode()) -> ok.
%% Any for anyone
verify_publish_qos_constraint(_QoS, _Mode) ->
    ok.

-spec verify_publish_retain_constraint(boolean(), connection_mode()) -> ok.
%% Any for 'service' mode
verify_publish_retain_constraint(_IsRetain, service) ->
    ok;
%% Only 'false' for anyone else
verify_publish_retain_constraint(false, _Mode) ->
    ok;
verify_publish_retain_constraint(IsRetain, _Mode) ->
    error({bad_retain, IsRetain}).

-spec verify_publish_topic(topic(), binary(), binary(), connection_mode()) -> ok.
%% Broadcast:
%% -> event(app-to-any): apps/ACCOUNT_ID(ME)/api/v1/BROADCAST_URI
verify_publish_topic([<<"apps">>, Me, <<"api">>, _ | _], Me, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service)
      or (Mode =:= observer) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% -> request(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
%% -> event(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
verify_publish_topic([<<"agents">>, Me, <<"api">>, _, <<"out">>, _], _AccountId, Me, _Mode)
    -> ok;
%% Unicast:
%% -> request(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
%% -> response(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
verify_publish_topic([<<"agents">>, _, <<"api">>, _, <<"in">>, Me], Me, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service)
      or (Mode =:= observer) or (Mode =:= bridge)
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
%% Observer can subscribe to any topic
verify_subscribe_topic(_Topic, _AccountId, _AgentId, observer)
    -> ok;
%% Broadcast:
%% <- event(any-from-app): apps/ACCOUNT_ID/api/v1/BROADCAST_URI
verify_subscribe_topic([<<"apps">>, _, <<"api">>, _ | _], _AccountId, _AgentId, Mode)
    when (Mode =:= service_payload_only) or (Mode =:= service) or (Mode =:= bridge)
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
%% API: Broker Start
%% =============================================================================

-spec handle_broker_start() -> ok.
handle_broker_start() ->
    handle_broker_start_stat_config().

-spec handle_broker_start_stat_config() -> ok.
handle_broker_start_stat_config() ->
    case mqttgw_state:find(stat) of
        {ok, {enabled, BMe}} ->
            BrokerId = broker_client_id(BMe),
            send_audience_event(
                #{id => agent_id(BrokerId)},
                <<"agent.enter">>,
                BrokerId,
                BrokerId),
            handle_broker_start_success();
        _ ->
            handle_broker_start_success()
    end.

handle_broker_start_success() ->
    ok.

%% =============================================================================
%% API: Broker Stop
%% =============================================================================

-spec handle_broker_stop() -> ok.
handle_broker_stop() ->
    handle_broker_stop_authz_config().

-spec handle_broker_stop_authz_config() -> ok.
handle_broker_stop_authz_config() ->
    case mqttgw_state:find(authz) of
        {ok, {enabled, BMe, _Config}} ->
            erase_dynsubs(broker_client_id(BMe)),
            handle_broker_stop_stat_config();
        _ ->
            handle_broker_stop_stat_config()
    end.

-spec handle_broker_stop_stat_config() -> ok.
handle_broker_stop_stat_config() ->
    case mqttgw_state:find(stat) of
        {ok, {enabled, BMe}} ->
            BrokerId = broker_client_id(BMe),
            send_audience_event(
                #{id => agent_id(BrokerId)},
                <<"agent.leave">>,
                BrokerId,
                BrokerId),
            handle_broker_stop_success();
        _ ->
            handle_broker_stop_success()
    end.

handle_broker_stop_success() ->
    ok.

%% =============================================================================
%% Plugin Callbacks
%% =============================================================================

-spec start() -> ok.
start() ->
    {ok, _} = application:ensure_all_started(?APP),
    mqttgw_state:put(authn, mqttgw_authn:read_config()),
    mqttgw_state:put(authz, mqttgw_authz:read_config()),
    mqttgw_state:put(stat, mqttgw_stat:read_config()),
    handle_broker_start(),
    ok.

-spec stop() -> ok.
stop() ->
    handle_broker_stop().

auth_on_register(
    _Peer, {_MountPoint, Conn} = _SubscriberId, _Username,
    Password, CleanSession) ->
    case handle_connect(Conn, Password, CleanSession) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_register_m5(
    _Peer, {_MountPoint, Conn} = _SubscriberId, _Username,
    Password, CleanSession, _Properties) ->
    handle_connect(Conn, Password, CleanSession).

auth_on_publish(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain) ->
    handle_publish_mqtt3_constraints(
        Topic, Payload, QoS, IsRetain,
        parse_client_id(Conn)).

auth_on_publish_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain, Properties) ->
    handle_publish_mqtt5_constraints(
        Topic, Payload, Properties, QoS, IsRetain,
        parse_client_id(Conn)).

on_deliver(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    _Topic, Payload) ->
    handle_deliver_mqtt3(Payload, parse_client_id(Conn)).

on_deliver_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    _Topic, Payload, Properties) ->
    handle_deliver_mqtt5(Payload, Properties, parse_client_id(Conn)).

auth_on_subscribe(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions) ->
    case handle_subscribe_authz(Subscriptions, parse_client_id(Conn)) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_subscribe_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions, _Properties) ->
    handle_subscribe_authz(Subscriptions, parse_client_id(Conn)).

on_client_offline({_MountPoint, Conn} = _SubscriberId) ->
    handle_disconnect(Conn).

on_client_gone({_MountPoint, Conn} = _SubscriberId) ->
    handle_disconnect(Conn).

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

-spec broker_client_id(mqttgw_id:agent_id()) -> client_id().
broker_client_id(AgentId) ->
    #client_id
        {mode = service,
         agent_label = mqttgw_id:label(AgentId),
         account_label = mqttgw_id:account_label(AgentId),
         audience = mqttgw_id:audience(AgentId)}.

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

-spec connection_versionmode(connection_mode()) -> {binary(), binary()}.
connection_versionmode(default)              -> {<<"v1">>, <<"agents">>};
connection_versionmode(service_payload_only) -> {<<"v1.payload-only">>, <<"service-agents">>};
connection_versionmode(service)              -> {<<"v1">>, <<"service-agents">>};
connection_versionmode(observer)             -> {<<"v1">>, <<"observer-agents">>};
connection_versionmode(bridge)               -> {<<"v1">>, <<"bridge-agents">>}.

-spec parse_client_id(binary()) -> client_id().
parse_client_id(<<"v1/agents/", R/bits>>) ->
    parse_v1_agent_label(R, default, <<>>);
parse_client_id(<<"v1.payload-only/service-agents/", R/bits>>) ->
    parse_v1_agent_label(R, service_payload_only, <<>>);
parse_client_id(<<"v1/service-agents/", R/bits>>) ->
    parse_v1_agent_label(R, service, <<>>);
parse_client_id(<<"v1/observer-agents/", R/bits>>) ->
    parse_v1_agent_label(R, observer, <<>>);
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
parse_envelope(Mode, Message)
    when (Mode =:= default) or (Mode =:= service)
      or (Mode =:= observer) or (Mode =:= bridge) ->
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

-spec create_dynsub(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
create_dynsub(Subject, Data) ->
    QoS = 1,
    Topic = authz_subscription_topic(Data),
    mqttgw_broker:subscribe(Subject, [{Topic, QoS}]),
    ok.

-spec delete_dynsub(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
delete_dynsub(Subject, Data) ->
    Topic = authz_subscription_topic(Data),
    mqttgw_broker:unsubscribe(Subject, [Topic]),
    ok.

-spec delete_client_dynsubs(mqttgw_dynsub:subject(), client_id()) -> ok.
delete_client_dynsubs(Subject, BrokerId) ->
    DynSubL = mqttgw_dynsub:list(Subject),

    %% Send a multicast event to the application
    [send_dynsub_event(<<"subscription.delete">>, Subject, Data, BrokerId) || Data <- DynSubL],

    %% Remove subscriptions
    [delete_dynsub(Subject, Data) || Data  <- DynSubL],

    ok.

-spec erase_dynsubs(client_id()) -> ok.
erase_dynsubs(BrokerId) ->
    [delete_client_dynsubs(Subject, BrokerId) || Subject <- mqttgw_broker:list_connections()],
    ok.

-spec send_dynsub_response(
    binary(), binary(), binary(), client_id(), client_id())
    -> ok.
send_dynsub_response(App, CorrData, RespTopic, BrokerId, SenderId) ->
    #client_id{mode=Mode} = SenderId,

    QoS = 1,
    try mqttgw_broker:publish(
        validate_dynsub_response_topic(binary:split(RespTopic, <<$/>>, [global]), App),
        envelope(
            #message{
                payload = jsx:encode(#{}),
                properties =
                    validate_message_properties(
                        update_message_properties(
                            #{p_correlation_data => CorrData,
                              p_user_property =>
                                [ {<<"type">>, <<"response">>},
                                  {<<"status">>, <<"200">>} ]},
                            SenderId
                        ),
                        SenderId
                    )}),
        QoS) of
        _ ->
            ok
    catch
        T:R ->
            error_logger:error_msg(
                "Error sending subscription success response to = '~s' "
                "from the agent = '~s' using mode = '~s' "
                "by the broker agent = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [RespTopic, agent_id(SenderId), Mode, agent_id(BrokerId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec send_dynsub_event(binary(), mqttgw_dynsub:subject(), mqttgw_dynsub:data(), client_id())
    -> ok.
send_dynsub_event(Label, Subject, Data, SenderId) ->
    QoS = 1,
    #{app := App, object := Object} = Data,
    try mqttgw_broker:publish(
        dynsub_event_topic(App, SenderId),
        envelope(
            #message{
                payload = jsx:encode(
                    #{object => Object,
                      subject => Subject}),
                properties =
                    validate_message_properties(
                        update_message_properties(
                            #{p_user_property =>
                                [ {<<"type">>, <<"event">>},
                                  {<<"label">>, Label} ]},
                            SenderId
                        ),
                        SenderId
                    )}),
        QoS) of
        _ ->
            ok
    catch
        T:R ->
            error_logger:error_msg(
                "Error sending subscription success event to = '~s' "
                "by the broker agent = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [App, agent_id(SenderId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec send_audience_event(map(), binary(), client_id(), client_id()) -> ok.
send_audience_event(Payload, Label, SenderId, ClientId) ->
    Topic = audience_event_topic(ClientId, SenderId),
    QoS = 1,
    try mqttgw_broker:publish(
        Topic,
        envelope(
            #message{
                payload = jsx:encode(Payload),
                properties =
                    validate_message_properties(
                        update_message_properties(
                            #{p_user_property =>
                                [ {<<"type">>, <<"event">>},
                                  {<<"label">>, Label} ]},
                            SenderId
                        ),
                        SenderId
                    )}),
        QoS) of
        _ ->
            ok
    catch
        T:R ->
            error_logger:error_msg(
                "Error sending audience event: label = '~s', topic = `~p` "
                "by the broker agent = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Label, Topic, agent_id(SenderId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec audience_event_topic(client_id(), client_id()) -> topic().
audience_event_topic(ClientId, BrokerId) ->
    [<<"apps">>, account_id(BrokerId),
     <<"api">>, <<"v1">>, <<"audiences">>, ClientId#client_id.audience, <<"events">>].

-spec dynsub_event_topic(binary(), client_id()) -> topic().
dynsub_event_topic(App, BrokerId) ->
    [<<"agents">>, agent_id(BrokerId),
     <<"api">>, <<"v1">>, <<"out">>, App].

-spec authz_subscription_topic(mqttgw_dynsub:data()) -> topic().
authz_subscription_topic(Data) ->
    #{app := App,
      object := Object,
      version := Version} = Data,
    [<<"apps">>, App, <<"api">>, Version | Object].

-spec validate_dynsub_response_topic(topic(), binary()) -> topic().
validate_dynsub_response_topic([<<"agents">>, _, <<"api">>, _, <<"in">>, App] = Topic, App) ->
    Topic;
validate_dynsub_response_topic(Topic, App) ->
    error({nomatch_app_in_broker_response_topic, Topic, App}).

-spec parse_broker_request_properties(map()) -> map().
parse_broker_request_properties(Properties) ->
    #{p_user_property := UserProperties,
      p_correlation_data := CorrData,
      p_response_topic := RespTopic} = Properties,
    {_, Type} = lists:keyfind(<<"type">>, 1, UserProperties),
    {_, Method} = lists:keyfind(<<"method">>, 1, UserProperties),
    #{type => Type,
      method => Method,
      correlation_data => CorrData,
      response_topic => RespTopic}.

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
             {<<"v1">>, <<"observer-agents">>},
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
        {Peer, SubscriberId, Username, Password},
        {any(), subscriber_id_t(), binary_utf8_t(), binary_utf8_t()},
        begin
            CleanSession = minimal_constraint(clean_session),

            mqttgw_state:new(),
            mqttgw_state:put(authn, disabled),
            mqttgw_state:put(authz, disabled),
            mqttgw_state:put(stat, disabled),
            ok = auth_on_register(Peer, SubscriberId, Username, Password, CleanSession),
            ok = auth_on_register_m5(Peer, SubscriberId, Username, Password, CleanSession, #{}),
            true
        end).

prop_onconnect_invalid_credentials() ->
    ?FORALL(
        {Peer, MountPoint, ClientId, Username, Password, InCleanSession},
        {any(), string(), binary(32), binary_utf8_t(), binary_utf8_t(), boolean()},
        begin
            CleanSession = minimal_constraint(clean_session),

            SubscriberId = {MountPoint, ClientId},
            {error, client_identifier_not_valid} =
                auth_on_register(Peer, SubscriberId, Username, Password, CleanSession),
            {error, #{reason_code := client_identifier_not_valid}} =
                auth_on_register_m5(Peer, SubscriberId, Username, Password, CleanSession, #{}),
            true
        end).

authz_onconnect_test_() ->
    CleanSession = minimal_constraint(clean_session),

    AgentLabel = <<"foo">>,
    AccountLabel = <<"bar">>,
    SvcAud = BMeAud = <<"svc.example.org">>,
    SvcAccountId = #{label => AccountLabel, audience => SvcAud},
    UsrAud = <<"usr.example.net">>,

    #{password := SvcPassword,
      config := SvcAuthnConfig} =
        make_sample_password(<<"bar">>, SvcAud, <<"svc.example.org">>),
    #{password := UsrPassword,
      config := UsrAuthnConfig} =
        make_sample_password(<<"bar">>, UsrAud, <<"iam.svc.example.net">>),
    #{me := BMe,
      config := AuthzConfig} = make_sample_me(BMeAud, [SvcAccountId]),

    Test = [
        { "usr: allowed",
          [default], UsrAud, UsrPassword,
          ok },
        { "usr: forbidden",
          [service_payload_only, service, observer, bridge], UsrAud, UsrPassword,
          {error, #{reason_code => not_authorized}} },
        { "svc: allowed",
          [default, service_payload_only, service, observer, bridge], SvcAud, SvcPassword,
          ok }
    ],

    mqttgw_state:new(),
    %% 1 - authn: enabled, authz: disabled
    %% Anyone can connect in any mode when authz is dissabled
    mqttgw_state:put(authn, {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)}),
    mqttgw_state:put(authz, disabled),
    mqttgw_state:put(stat, disabled),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(ok, handle_connect(ClientId, Password, CleanSession))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, _Result} <- Test],
    %% 2 - authn: enabled, authz: enabled
    %% User accounts can connect only in 'default' mode
    %% Service accounts can connect in any mode
    mqttgw_state:put(authz, {enabled, BMe, AuthzConfig}),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(Result, handle_connect(ClientId, Password, CleanSession))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Result} <- Test],
    %% 3 - authn: disabled, authz: enabled
    mqttgw_state:put(authn, disabled),
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, <<"v1">>),
            {Desc, ?_assertEqual(Result, handle_connect(ClientId, Password, CleanSession))}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Result} <- Test].

message_connect_constraints_test_() ->
    AnyMode = [default, service, service_payload_only, observer, bridge],
    TrustedMode = [service, service_payload_only, observer, bridge],
    NonTrustedMode = AnyMode -- TrustedMode,
    AnyCleanSession = [false, true],
    MinCleanSession = [true],

    Test = [
        {"trusted: any clean_session", AnyCleanSession, TrustedMode, ok},
        {"nontrusted: w/ clean_session", [true], NonTrustedMode, ok},
        {"nontrusted: w/o clean_session", [false], NonTrustedMode, error}
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, disabled),
    mqttgw_state:put(stat, disabled),
    [begin
        [begin
            [begin
                Result =
                    try verify_connect_constraints(CleanSession, Mode) of
                        _ ->
                            ok
                    catch
                        _:_ ->
                            error
                    end,
                {Desc, ?_assertEqual(Expect, Result)}
            end || CleanSession <- CleanSessionL]
        end || Mode <- Modes]
    end || {Desc, CleanSessionL, Modes, Expect} <- Test].

prop_onpublish() ->
    ?FORALL(
        {Username, SubscriberId, Topic, Payload},
        {binary_utf8_t(), subscriber_id_t(), publish_topic_t(), binary_utf8_t()},
        begin
            QoS = minimal_constraint(qos),
            IsRetain = minimal_constraint(retain),

            mqttgw_state:new(),
            mqttgw_state:put(authz, disabled),
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            {VersionStr, ModeStr} = connection_versionmode(Mode),
            ExpectedConnectionL =
                [ {<<"connection_version">>, VersionStr},
                  {<<"connection_mode">>, ModeStr} ],
            ExpectedAuthnUserL =
                [ {<<"agent_label">>, AgentLabel},
                  {<<"account_label">>, AccountLabel},
                  {<<"audience">>, Audience} ],
            ExpectedAuthnProperties = #{p_user_property => ExpectedAuthnUserL},
            ExpectedUserL = [{<<"type">>, <<"event">>} | ExpectedAuthnUserL ++ ExpectedConnectionL],
            ExpectedProperties = #{p_user_property => ExpectedUserL},

            %% MQTT 5
            begin
                {InputPayload, InputProperties} =
                    case Mode of
                        M5 when (M5 =:= default) or (M5 =:= service) or (M5 =:= observer) ->
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
                        M3 when (M3 =:= default) or (M3 =:= service) or (M3 =:= observer) ->
                            envelope(make_sample_message_bridgepropsonly(
                                Mode, Payload));
                        bridge ->
                            envelope(make_sample_message_bridgepropsonly(
                                Mode, Payload, ExpectedAuthnProperties));
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
    QoS = minimal_constraint(qos),
    IsRetain = minimal_constraint(retain),
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
    %% -> event(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
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
        {"svc: broadcast", Broadcast, [service_payload_only, service, observer, bridge], ok},
        {"svc: multicast", Multicast, [service_payload_only, service, observer, bridge], ok},
        {"svc: unicast", Unicast, [service_payload_only, service, observer, bridge], ok}
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, {enabled, maps:get(me, make_sample_me(<<"aud">>, [])), ignore}),
    [begin
        [begin
            Message = make_sample_message_bridgecompat(Mode),
            ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode),
            Result =
                case handle_publish_authz(TopicFn(ClientId), Message, ClientId) of
                    ok -> ok;
                    {error, _} -> error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, TopicFn, Modes, Expect} <- Test].

message_publish_constraints_test_() ->
    AnyMode = [default, service, service_payload_only, observer, bridge],
    ServiceMode = [service],
    NonServiceMode = AnyMode -- ServiceMode,
    AnyQoS = [0, 1, 2],
    MinQoS = [0],
    AnyRetain = [false, true],
    MinRetain = [false],

    Test = [
        {"qos: any", AnyQoS, MinRetain, AnyMode, ok},
        {"svc: any retain", MinQoS, AnyRetain, ServiceMode, ok},
        {"nonsvc: w/ retain", MinQoS, [true], NonServiceMode, error},
        {"nonsvc: w/o retain", MinQoS, [false], NonServiceMode}
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, disabled),
    [begin
        [begin
            [begin
                [begin
                    Result =
                        try verify_publish_constraints(QoS, IsRetain, Mode) of
                            _ ->
                                ok
                        catch
                            _:_ ->
                                error
                        end,
                    {Desc, ?_assertEqual(Expect, Result)}
                end || QoS <- QoSL]
            end || IsRetain <- RetainL]
        end || Mode <- Modes]
    end || {Desc, QoSL, RetainL, Modes, Expect} <- Test].

message_properties_test_() ->
    ClientId = fun(Mode) ->
        make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode)
    end,
    ResponseTopic = fun() ->
        <<"agents/", (agent_id(ClientId(default)))/binary, "/api/v1/in/baz.aud.example.org">>
    end,
    BadResponseTopic = fun() ->
        <<"agents/another.bar.aud.example.org/api/v1/in/baz.aud.example.org">>
    end,

    AnyMode = [default, service, service_payload_only, observer, bridge],
    ServiceMode = [service],
    NonServiceMode = AnyMode -- ServiceMode,

    Test = [
        { "type: no",
          AnyMode,
          #{},
          ok },
        { "type: any",
          AnyMode,
          #{p_user_property => [{<<"type">>, <<"any">>}]},
          ok },
        { "type: request, no method",
          AnyMode,
          #{p_user_property => [{<<"type">>, <<"request">>}]},
          error },
        { "type: request, no correlation_data",
          AnyMode,
          #{p_user_property => [{<<"type">>, <<"request">>}, {<<"method">>, <<>>}]},
          error },
        { "type: request, no response_topic",
          AnyMode,
          #{p_user_property => [{<<"type">>, <<"request">>}, {<<"method">>, <<>>}],
            p_correlation_data => <<>>},
          error },
        { "type: request, with response_topic",
          AnyMode,
          #{p_user_property => [{<<"type">>, <<"request">>}, {<<"method">>, <<>>}],
            p_correlation_data => <<>>,
            p_response_topic => ResponseTopic()},
          ok },
        { "type: request, bad response_topic",
          ServiceMode,
          #{p_user_property => [{<<"type">>, <<"request">>}, {<<"method">>, <<>>}],
            p_correlation_data => <<>>,
            p_response_topic => BadResponseTopic()},
          ok },
        { "type: request, bad response_topic",
            NonServiceMode,
            #{p_user_property => [{<<"type">>, <<"request">>}, {<<"method">>, <<>>}],
              p_correlation_data => <<>>,
              p_response_topic => BadResponseTopic()},
          error },
        { "user property key: number",
          AnyMode, #{p_user_property => [{1, <<"num">>}]},
          error },
        { "user property value: number",
          AnyMode,
          #{p_user_property => [{<<"num">>, 1}]},
          error }
    ],

    mqttgw_state:new(),
    mqttgw_state:put(authz, disabled),
    [begin
        [begin
            Message = make_sample_message_bridgecompat(Mode, <<>>, Props),
            Result =
                try handle_message_properties(Message, ClientId(Mode)) of
                    _ ->
                        ok
                catch
                    _:_ ->
                        error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Props, Expect} <- Test].

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
                        observer             -> InputPayload;
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
        {"usr: broadcast", Broadcast, [default], {error, #{reason_code => not_authorized}}},
        {"usr: multicast", Multicast, [default], {error, #{reason_code => not_authorized}}},
        {"usr: unicast", Unicast, [default], ok},
        {"svc: broadcast", Broadcast, [service_payload_only, service, observer, bridge], ok},
        {"svc: multicast", Multicast, [service_payload_only, service, observer, bridge], ok},
        {"svc: unicast", Unicast, [service_payload_only, service, observer, bridge], ok}
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

minimal_constraint(clean_session) -> true;
minimal_constraint(retain) -> false;
minimal_constraint(qos) -> 0.

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

make_sample_me(BMeAud, Trusted) ->
    BMe = #{label => <<"alpha">>, account_id => #{label => <<"mqtt-gateway">>, audience => BMeAud}},
    Config =
        #{BMeAud =>
          #{type => trusted,
            trusted => gb_sets:from_list(Trusted)}},

    #{me => BMe,
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
            observer -> <<Version/binary, "/observer-agents">>;
            bridge -> <<Version/binary, "/bridge-agents">>
        end,

    <<ModeLabel/binary, $/, AgentId/binary>>.

make_sample_message_bridgecompat(Mode) ->
    make_sample_message_bridgecompat(Mode, <<>>, #{}).

make_sample_message_bridgecompat(Mode, Payload, Properties) ->
    case Mode of
        Mode when
            (Mode =:= default) or (Mode =:= service_payload_only) or (Mode =:= service) or
            (Mode =:= observer) ->
            #message{
                payload = Payload,
                properties = Properties};
        bridge ->
            #message
                {payload = Payload,
                properties = update_sample_message_properties(Mode, Properties)};
        _ ->
            error({bad_mode, Mode})
    end.

update_sample_message_properties(Mode, Properties) ->
    {VersionStr, ModeStr} = connection_versionmode(Mode),
    DefaultSampleUserProperties =
        #{ <<"agent_label">> => <<"test-1">>,
           <<"account_label">> => <<"john-doe">>,
           <<"audience">> => <<"example.org">>},

    UserProperties0 = maps:from_list(maps:get(p_user_property, Properties, [])),
    UserProperties1 = maps:merge(DefaultSampleUserProperties, UserProperties0),
    Properties#{p_user_property => maps:to_list(UserProperties1)}.


make_sample_message_bridgepropsonly(Mode, Payload) ->
    make_sample_message_bridgepropsonly(Mode, Payload, #{}).

make_sample_message_bridgepropsonly(Mode, Payload, Properties) ->
    case Mode of
        Mode when
            (Mode =:= default) or (Mode =:= service_payload_only) or (Mode =:= service) or
            (Mode =:= observer) ->
            #message{
                payload = Payload};
        bridge ->
            #message{
                payload = Payload,
                properties = Properties};
        _ ->
            error({bad_mode, Mode})
    end.

-endif.
