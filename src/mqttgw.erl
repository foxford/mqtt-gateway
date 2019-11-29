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
    handle_connect/5,
    handle_publish_mqtt3/4,
    handle_publish_mqtt5/5,
    handle_publish_authz/4,
    handle_deliver_mqtt3/4,
    handle_deliver_mqtt5/5,
    handle_subscribe_authz/3
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
-define(VER_1, <<"v1">>).
-define(VER_2, <<"v2">>).
-define(BROKER_CONNECTION, #connection{mode=service, version=?VER_2}).
-define(BROKER_V1COMPAT_CONNECTION, #connection{mode=service, version=?VER_1}).

%% Types
-type qos() :: 0..2.
-type topic() :: [binary()].
-type subscription() :: {topic(), qos()}.
-type connection_mode() :: default | service | observer | bridge.

-record(connection, {
    version :: binary(),
    mode    :: connection_mode()
}).
-type connection() :: #connection{}.

-record(session, {
    id         :: binary(),
    parent_id  :: binary(),
    connection :: connection(),
    created_at :: non_neg_integer()
}).
-type session() :: #session{}.

-record(config, {
    id      :: mqttgw_id:agent_id(),
    authn   :: mqttgw_authn:config(),
    authz   :: mqttgw_authz:config(),
    stat    :: mqttgw_stat:config()
}).
-type config() :: #config{}.

-record(initial_state, {
    config  :: config(),
    time    :: non_neg_integer()
}).
-type initial_state() :: #initial_state{}.

-record(state, {
    config    :: config(),
    session   :: session(),
    unique_id :: binary(),
    time      :: non_neg_integer()
}).
-type state() :: #state{}.

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

-spec handle_connect(binary(), binary(), boolean(), map(), initial_state())
    -> ok | {error, error()}.
handle_connect(ClientId, Password, CleanSession, Properties, State) ->
    try validate_connection_params(parse_connection_params(ClientId, Properties)) of
        {Conn, AgentId} ->
            handle_connect_constraints(Conn, AgentId, Password, CleanSession, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid client_id = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [ClientId, T, R]),
            {error, #{reason_code => client_identifier_not_valid}}
    end.

-spec handle_connect_constraints(
    connection(), mqttgw_id:agent_id(), binary(), boolean(), initial_state())
    -> ok | {error, error()}.
handle_connect_constraints(Conn, AgentId, Password, CleanSession, State) ->
    try verify_connect_constraints(CleanSession, Conn#connection.mode) of
        _ ->
            handle_connect_authn_config(Conn, AgentId, Password, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: invalid constraints check, clean_session = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [CleanSession, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_connect_authn_config(connection(), mqttgw_id:agent_id(), binary(), initial_state())
    -> ok | {error, error()}.
handle_connect_authn_config(Conn, AgentId, Password, State) ->
    case State#initial_state.config#config.authn of
        disabled ->
            DirtyAccountId = mqttgw_id:account_id(AgentId),
            handle_connect_authz_config(Conn, AgentId, DirtyAccountId, State);
        {enabled, Config} ->
            handle_connect_authn(Conn, AgentId, Password, Config, State)
    end.

-spec handle_connect_authn(
    connection(), mqttgw_id:agent_id(), binary(), mqttgw_authn:config(), initial_state())
    -> ok | {error, error()}.
handle_connect_authn(Conn, AgentId, Password, Config, State) ->
    DirtyAccountId = mqttgw_id:account_id(AgentId),
    try mqttgw_authn:authenticate(Password, Config) of
        AccountId when AccountId =:= DirtyAccountId ->
            handle_connect_authz_config(Conn, AgentId, AccountId, State);
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
                [mqttgw_id:format_agent_id(AgentId), T, R]),
            {error, #{reason_code => bad_username_or_password}}
    end.

-spec handle_connect_authz_config(
    connection(), mqttgw_id:agent_id(), mqttgw_authn:account_id(), initial_state())
    -> ok | {error, error()}.
handle_connect_authz_config(Conn, AgentId, AccountId, State) ->
    case State#initial_state.config#config.authz of
        disabled ->
            handle_connect_success(Conn, AgentId, State);
        {enabled, Config} ->
            BrokerId = State#initial_state.config#config.id,
            handle_connect_authz(Conn, AgentId, AccountId, BrokerId, Config, State)
    end.

-spec handle_connect_authz(
    connection(), mqttgw_id:agent_id(), mqttgw_authn:account_id(),
    mqttgw_id:agent_id(), mqttgw_authz:config(), initial_state())
    -> ok | {error, error()}.
handle_connect_authz(
    #connection{mode=default} =Conn, AgentId, _AccountId, _BrokerId, _Config, State) ->
    handle_connect_success(Conn, AgentId, State);
handle_connect_authz(Conn, AgentId, AccountId, BrokerId, Config, State) ->
    #connection{mode=Mode} = Conn,

    try mqttgw_authz:authorize(mqttgw_id:audience(BrokerId), AccountId, Config) of
        _ ->
            handle_connect_success(Conn, AgentId, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: connecting in mode = '~s' isn't allowed "
                "for the agent = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Mode, mqttgw_id:format_agent_id(AgentId), T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_success(
    connection(), mqttgw_id:agent_id(), initial_state())
    -> ok | {error, error()}.
handle_connect_success(Conn, AgentId, State) ->
    #connection{mode=Mode, version=Ver} = Conn,

    %% Get the broker session id
    Config = mqttgw_state:get(config),
    BrokerId = Config#config.id,
    #session{id=ParentSessionId} = mqttgw_state:get(BrokerId),

    %% Create an agent session
    Session =
        #session{
            id=make_uuid(),
            parent_id=ParentSessionId,
            connection=Conn,
            created_at=State#initial_state.time},
    mqttgw_state:put(AgentId, Session),

    handle_connect_success_stat_config(
        AgentId,
        broker_state(
            State#initial_state.config,
            Session,
            State#initial_state.time)),

    error_logger:info_msg(
        "Agent = '~s' connected: mode = '~s', version = '~s'",
        [mqttgw_id:format_agent_id(AgentId), Mode, Ver]),
    ok.

-spec handle_connect_success_stat_config(mqttgw_id:agent_id(), state()) -> ok.
handle_connect_success_stat_config(AgentId, State) ->
    case State#state.config#config.stat of
        disabled ->
            ok;
        enabled ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{
                    id=SessionId,
                    parent_id=ParentSessionId,
                    created_at=Ts},
                config=#config{
                    id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => mqttgw_id:format_agent_id(AgentId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_CONNECTION,
                BrokerId,
                AgentId,
                UniqueId,
                SessionPairId,
                Time),
            %% TODO: remove v1
            send_audience_event(
                #{id => mqttgw_id:format_agent_id(AgentId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_V1COMPAT_CONNECTION,
                BrokerId,
                AgentId,
                UniqueId,
                SessionPairId,
                Time),
            ok
    end.

-spec verify_connect_constraints(boolean(), connection_mode()) -> ok.
verify_connect_constraints(CleanSession, Mode) ->
    ok = verify_connect_clean_session_constraint(CleanSession, Mode),
    ok.

-spec verify_connect_clean_session_constraint(boolean(), connection_mode()) -> ok.
%% Any for trusted modes
verify_connect_clean_session_constraint(_IsRetain, Mode)
    when (Mode =:= service) or (Mode =:= bridge) or (Mode =:= observer)
    -> ok;
%% Only 'false' for anyone else
verify_connect_clean_session_constraint(true, _Mode) ->
    ok;
verify_connect_clean_session_constraint(IsRetain, _Mode) ->
    error({bad_retain, IsRetain}).

%% =============================================================================
%% API: Disconnect
%% =============================================================================

-spec handle_disconnect(binary(), mqttgw_id:agent_id(), state()) -> ok.
handle_disconnect(ClientId, AgentId, State) ->
    handle_disconnect_authz_config(ClientId, AgentId, State).

-spec handle_disconnect_authz_config(binary(), mqttgw_id:agent_id(), state()) -> ok.
handle_disconnect_authz_config(ClientId, AgentId, State) ->
    case State#state.config#config.authz of
        disabled ->
            handle_disconnect_stat_config(AgentId, State);
        {enabled, _Config} ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{id=SessionId, parent_id=ParentSessionId},
                config=#config{id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            delete_client_dynsubs(
                ClientId, ?BROKER_CONNECTION, BrokerId, UniqueId, SessionPairId, Time),
            handle_disconnect_stat_config(AgentId, State)
    end.

-spec handle_disconnect_stat_config(mqttgw_id:agent_id(), state()) -> ok | {error, error()}.
handle_disconnect_stat_config(AgentId, State) ->
    case State#state.config#config.stat of
        disabled ->
            handle_disconnect_success(AgentId, State);
        enabled ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{
                    id=SessionId,
                    parent_id=ParentSessionId,
                    created_at=Ts},
                config=#config{
                    id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => mqttgw_id:format_agent_id(AgentId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_CONNECTION,
                BrokerId,
                AgentId,
                UniqueId,
                SessionPairId,
                Time),
            %% TODO: remove v1
            send_audience_event(
                #{id => mqttgw_id:format_agent_id(AgentId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_V1COMPAT_CONNECTION,
                BrokerId,
                AgentId,
                UniqueId,
                SessionPairId,
                Time),
            handle_disconnect_success(AgentId, State)
    end.

-spec handle_disconnect_success(mqttgw_id:agent_id(), state()) -> ok.
handle_disconnect_success(AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    error_logger:info_msg(
        "Agent = '~s' disconnected: mode = '~s'",
        [mqttgw_id:format_agent_id(AgentId), Mode]),
    ok.

%% =============================================================================
%% API: Publish
%% =============================================================================

-spec handle_publish_mqtt3_constraints(
    topic(), binary(), qos(), boolean(), mqttgw_id:agent_id(), state())
    -> {ok, list()} | {error, error()}.
handle_publish_mqtt3_constraints(Topic, InputPayload, QoS, IsRetain, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt3(Topic, InputPayload, AgentId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt3(topic(), binary(), mqttgw_id:agent_id(), state())
    -> {ok, list()} | {error, error()}.
handle_publish_mqtt3(Topic, InputPayload, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    BrokerId = State#state.config#config.id,
    try handle_message_properties(
        handle_mqtt3_envelope_properties(validate_envelope(parse_envelope(InputPayload))),
        AgentId,
        BrokerId,
        State) of
        Message ->
            case handle_publish_authz(Topic, Message, AgentId, State) of
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
                [InputPayload, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt5_constraints(
    topic(), binary(), map(), qos(), boolean(), mqttgw_id:agent_id(), state())
    -> {ok, map()} | {error, error()}.
handle_publish_mqtt5_constraints(
    Topic, InputPayload, InputProperties, QoS, IsRetain, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt5(Topic, InputPayload, InputProperties, AgentId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt5(topic(), binary(), map(), mqttgw_id:agent_id(), state())
    -> {ok, map()} | {error, error()}.
handle_publish_mqtt5(Topic, InputPayload, InputProperties, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    BrokerId = State#state.config#config.id,
    InputMessage = #message{payload = InputPayload, properties = InputProperties},
    try handle_message_properties(InputMessage, AgentId, BrokerId, State) of
        Message ->
            case handle_publish_authz(Topic, Message, AgentId, State) of
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
                [InputPayload, InputProperties, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_authz(topic(), message(), mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_publish_authz(Topic, Message, AgentId, State) ->
    handle_publish_authz_config(Topic, Message, AgentId, State).

-spec handle_publish_authz_config(topic(), message(), mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_publish_authz_config(Topic, Message, AgentId, State) ->
    case State#state.config#config.authz of
        disabled ->
            ok;
        {enabled, _Config} ->
            BrokerId = State#state.config#config.id,
            handle_publish_authz_topic(
                Topic, Message, BrokerId, AgentId, State)
    end.

-spec handle_publish_authz_topic(
    topic(), message(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_publish_authz_topic(Topic, Message, BrokerId, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    try verify_publish_topic(
        Topic, mqttgw_id:format_account_id(AgentId), mqttgw_id:format_agent_id(AgentId), Mode) of
        _ ->
            handle_publish_authz_broker_request(
                Topic, Message, mqttgw_id:format_account_id(BrokerId),
                mqttgw_id:format_agent_id(BrokerId), BrokerId, AgentId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: publishing to the topic = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Topic, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

-spec handle_publish_authz_broker_request(
    topic(), message(), binary(), binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
% handle_publish_authz_broker_request(
%     [<<"agents">>, _, <<"api">>, Version, <<"out">>, BrokerAccoundId],
%     Message, BrokerAccoundId, _BrokerAgentId, BrokerId, AgentId, State) ->
%         handle_publish_authz_broker_request_payload(Version, Message, BrokerId, AgentId, State);
handle_publish_authz_broker_request(
    _Topic, _Message, _BrokerAccoundId, _BrokerAgentId, _BrokerId, _AgentId, _State) ->
        ok.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

% -spec handle_publish_authz_broker_request_payload(
%    binary(), message(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_request_payload(
%     Version, #message{payload = Payload, properties = Properties}, BrokerId, AgentId, State) ->
%     #state{session=#session{connection=#connection{mode=Mode}}} = State,

%     try {Mode, jsx:decode(Payload, [return_maps]), parse_broker_request_properties(Properties)} of
%         {service,
%          #{<<"object">> := Object,
%            <<"subject">> := Subject},
%          #{type := <<"request">>,
%            method := <<"subscription.create">>,
%            correlation_data := CorrData,
%            response_topic := RespTopic}} ->
%                handle_publish_authz_broker_dynsub_create_request(
%                    Version, Object, Subject, CorrData, RespTopic, BrokerId, AgentId, State);
%         {service,
%          #{<<"object">> := Object,
%            <<"subject">> := Subject},
%          #{type := <<"request">>,
%            method := <<"subscription.delete">>,
%            correlation_data := CorrData,
%            response_topic := RespTopic}} ->
%                handle_publish_authz_broker_dynsub_delete_request(
%                    Version, Object, Subject, CorrData, RespTopic, BrokerId, AgentId, State);
%         _ ->
%             error_logger:error_msg(
%                 "Error on publish: unsupported broker request = ~p with properties = ~p "
%                 "from the agent = '~s' using mode = '~s', ",
%                 [Payload, Properties, mqttgw_id:format_agent_id(AgentId), Mode]),
%             {error, #{reason_code => impl_specific_error}}
%     catch
%         T:R ->
%             error_logger:error_msg(
%                 "Error on publish: an invalid broker request = ~p with properties = ~p "
%                 "from the agent = '~s' using mode = '~s', "
%                 "exception_type = ~p, exception_reason = ~p",
%                 [Payload, Properties, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
%             {error, #{reason_code => impl_specific_error}}
%     end.

% -spec handle_publish_authz_broker_dynsub_create_request(
%     binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
%     binary(), binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_dynsub_create_request(
%     Version, Object, Subject, CorrData, RespTopic, BrokerId, AgentId, State) ->
%     #state{
%         time=Time,
%         unique_id=UniqueId,
%         session=#session{id=SessionId, parent_id=ParentSessionId, connection=Conn}} = State,
%     SessionPairId = format_session_id(SessionId, ParentSessionId),

%     %% Subscribe the agent to the app's topic and send a success response
%     App = mqttgw_authn:format_account_id(AgentId),
%     Data = #{app => App, object => Object, version => Version},
%     create_dynsub(Subject, Data),

%     %% Send an unicast response to the 3rd-party agent
%     send_dynsub_response(
%         App, CorrData, RespTopic, BrokerId, Conn, AgentId,
%         UniqueId, SessionPairId, Time),

%     %% Send a multicast event to the application
%     send_dynsub_event(
%         <<"subscription.create">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
%         UniqueId, SessionPairId, Time),
%     ok.

% -spec handle_publish_authz_broker_dynsub_delete_request(
%     binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
%     binary(), binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_dynsub_delete_request(
%     Version, Object, Subject, CorrData, RespTopic, BrokerId, AgentId, State) ->
%     #state{
%         time=Time,
%         unique_id=UniqueId,
%         session=#session{id=SessionId, parent_id=ParentSessionId, connection=Conn}} = State,
%     SessionPairId = format_session_id(SessionId, ParentSessionId),

%     %% Unsubscribe the agent from the app's topic and send a success response
%     App = mqttgw_authn:format_account_id(AgentId),
%     Data = #{app => App, object => Object, version => Version},
%     delete_dynsub(Subject, Data),

%     %% Send an unicast response to the 3rd-party agent
%     send_dynsub_response(
%         App, CorrData, RespTopic, BrokerId, Conn, AgentId,
%         UniqueId, SessionPairId, Time),

%     %% Send a multicast event to the application
%     send_dynsub_event(
%         <<"subscription.delete">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
%         UniqueId, SessionPairId, Time),
%     ok.

-spec handle_message_properties(message(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_message_properties(Message, AgentId, BrokerId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId, connection=Conn}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    UpdatedProperties =
        validate_message_properties(
            update_message_properties(
                Message#message.properties,
                Conn,
                AgentId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
            Conn,
            AgentId),

    Message#message{
        properties = UpdatedProperties}.

-spec validate_message_properties(map(), connection(), mqttgw_id:agent_id()) -> map().
validate_message_properties(Properties, Conn, AgentId) ->
    #connection{mode=Mode} = Conn,
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
            %% Required properties:
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
                    verify_response_topic(
                        binary:split(RT, <<$/>>, [global]),
                        mqttgw_id:format_agent_id(AgentId))
            end;
        {ok, <<"response">>} ->
            %% Required properties:
            %% - p_user_property(status)
            %% - p_correlation_data
            case
                { maps:find(<<"status">>, UserProperties),
                  maps:find(p_correlation_data, Properties) } of

                {error, _} -> error({missing_status_user_property, Properties});
                {_, error} -> error({missing_correlation_data_property, Properties});
                _ -> ok
            end;
        {ok, <<"event">>} ->
            %% Required properties:
            %% - p_user_property(label)
            case maps:find(<<"label">>, UserProperties) of
                error -> error({missing_label_user_property, Properties});
                _ -> ok
            end;
        _ ->
            ok
    end,

    %% Required properties for mode=default
    %% NOTE: default agent must always pass 'local_timestamp' property
    case {Mode, maps:find(<<"local_initial_timediff">>, UserProperties)} of
        {default, error} -> error({missing_local_initial_timediff_user_property, Properties});
        _ -> ok
    end,

    Properties.

-spec verify_response_topic(topic(), binary()) -> ok.
verify_response_topic([<<"agents">>, Me, <<"api">>, _, <<"in">>, _], Me) ->
    ok;
verify_response_topic(Topic, AgentId) ->
    error({bad_response_topic, Topic, AgentId}).

-spec update_message_properties(
    map(), connection(), mqttgw_id:agent_id(), mqttgw_id:agent_id(),
    binary(), binary(), non_neg_integer())
    -> map().
update_message_properties(Properties, Conn, AgentId, BrokerId, UniqueId, SessionPairId, Time) ->
    #{label := BrokerAgentLabel,
      account_id := #{
          label := BrokerAccountLabel,
          audience := BrokerAudience}} = BrokerId,
    #{label := AgentLabel,
      account_id := #{
          label := AccountLabel,
          audience := Audience}} = AgentId,
    #connection{mode=Mode, version=Ver} = Conn,

    TimeB = integer_to_binary(Time),
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
                %% TODO: remove v1
                % validate_authn_properties(UserProperties1);
                %% TODO: add validation of 'agent_id' property
                UserProperties1;
            _ ->
                UserProperties1#{
                    <<"agent_id">> => mqttgw_id:format_agent_id(AgentId),
                    %% TODO: remove v1: agent_label, account_label, audience properties
                    <<"agent_label">> => AgentLabel,
                    <<"account_label">> => AccountLabel,
                    <<"audience">> => Audience}
        end,

    %% Additional connection properties
    UserProperties3 =
        UserProperties2#{
            <<"connection_version">> => Ver,
            <<"connection_mode">> => format_v1compat_connection_mode(Ver, Mode)},

    %% Additional broker properties
    UserProperties4 =
        UserProperties3#{
            <<"broker_id">> => mqttgw_id:format_agent_id(BrokerId),
            %% TODO: remove v1: broker_agent_label, broker_account_label, broker_audience properties
            <<"broker_agent_label">> => BrokerAgentLabel,
            <<"broker_account_label">> => BrokerAccountLabel,
            <<"broker_audience">> => BrokerAudience},
    UserProperties5 =
        case maps:find(<<"broker_initial_processing_timestamp">>, UserProperties4) of
            {ok, _BrokerInitProcTs} ->
                UserProperties4#{
                    <<"broker_processing_timestamp">> => TimeB};
            _ ->
                UserProperties4#{
                    <<"broker_processing_timestamp">> => TimeB,
                    <<"broker_initial_processing_timestamp">> => TimeB}
        end,

    %% Additional svc properties
    UserProperties6 =
        case {
            maps:find(<<"timestamp">>, UserProperties5),
            maps:find(<<"initial_timestamp">>, UserProperties5)} of
            {{ok, Timestamp}, error} ->
                UserProperties5#{
                    <<"initial_timestamp">> => Timestamp};
            _ ->
                UserProperties5
        end,

    %% Additional usr properties
    UserProperties7 =
        case {
            maps:take(<<"local_timestamp">>, UserProperties6),
            maps:find(<<"local_initial_timediff">>, UserProperties6)} of
            %% NOTE: remove 'local_initial_timediff' if it was sent by an agent in 'default' mode
            {error, {ok, _}} when Mode =:= default ->
                remove_property(<<"local_initial_timediff">>, UserProperties6);
            {{LocalTs, Prop7}, error} ->
                LocalTimeDiff = integer_to_binary(Time - binary_to_integer(LocalTs)),
                Prop7#{<<"local_initial_timediff">> => LocalTimeDiff};
            _ ->
                UserProperties6
        end,

    %% Tracking properties
    UserProperties8 =
        case Mode of
            %% NOTE: remove 'tracking_id' if it was sent by an agent in 'default' mode
            default -> remove_property(<<"tracking_id">>, UserProperties7);
            _ -> UserProperties7
        end,
    UserProperties9 =
        update_session_tracking_label_property(
            UniqueId,
            SessionPairId,
            UserProperties8),

    Properties#{p_user_property => maps:to_list(UserProperties9)}.

-spec update_session_tracking_label_property(binary(), binary(), map()) -> map().
update_session_tracking_label_property(UniqueId, SessionPairId, UserProperties) ->
    case maps:find(<<"session_tracking_label">>, UserProperties) of
        {ok, SessionTrackingLabel} ->
            L0 = binary:split(SessionTrackingLabel, <<$\s>>, [global]),
            L1 = gb_sets:to_list(gb_sets:add(SessionPairId, gb_sets:from_list(L0))),
            UserProperties#{
                <<"session_tracking_label">> => binary_join(L1, <<$\s>>)};
        _ ->
            TrackingId = format_tracking_id(UniqueId, SessionPairId),
            UserProperties#{
                <<"tracking_id">> => TrackingId,
                <<"session_tracking_label">> => SessionPairId}
    end.

-spec remove_property(binary(), map()) -> map().
remove_property(Name, UserProperties) ->
    case maps:take(Name, UserProperties) of
        {ok, M} -> M;
        _ -> UserProperties
    end.

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
    when (Mode =:= service) or (Mode =:= observer) or (Mode =:= bridge)
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
    when (Mode =:= service) or (Mode =:= observer) or (Mode =:= bridge)
    -> ok;
%% Forbidding publishing to any other topics
verify_publish_topic(Topic, _AccountId, AgentId, Mode)
    -> error({nomatch_publish_topic, Topic, AgentId, Mode}).

%% =============================================================================
%% API: Deliver
%% =============================================================================

%% TODO: remove the local state
%% START >>>>>
%% The unicast requests don't have any advantages over multicast ones,
%% and add a possibility of creating a bottle neck.
%% The only reason we need them now is the local state.
%% This redundant behavior hopefully will be unnecessary with resolving of the 'issue:1326'.
%% https://github.com/vernemq/vernemq/issues/1326
-spec handle_deliver_authz_config(topic(), message(), mqttgw_id:agent_id(), state()) -> message().
handle_deliver_authz_config(Topic, Message, RecvId, State) ->
    case State#state.config#config.authz of
        disabled ->
            Message;
        {enabled, _Config} ->
            BrokerId = State#state.config#config.id,
            handle_deliver_authz_broker_request(
                Topic, Message, BrokerId, RecvId, State)
    end.

-spec handle_deliver_authz_broker_request(
    topic(), message(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_authz_broker_request(Topic, Message, BrokerId, RecvId, State) ->
    #message{properties = Props} = Message,
    case maps:find(p_response_topic, Props) of
        {ok, RTstr} ->
            case binary:split(RTstr, <<$/>>, [global]) of
                %% We consider the request as a broker request if "response topic" matches "topic".
                [<<"agents">>, _, <<"api">>, Version, <<"in">>, App] = RT when RT =:= Topic ->
                    handle_deliver_authz_broker_request_payload(
                        Version, App, Message, BrokerId, RecvId, State);
                _ ->
                    Message
            end;
        _ ->
            Message
    end.

-spec handle_deliver_authz_broker_request_payload(
    binary(), binary(), message(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_authz_broker_request_payload(
    Version, App, #message{payload = Payload, properties = Properties} =Message,
    BrokerId, RecvId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    try {jsx:decode(Payload, [return_maps]), parse_deliver_broker_request_properties(Properties)} of
        {#{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.create">>,
           connection_mode := service,
           correlation_data := CorrData,
           sent_by := AgentId}} ->
                case catch parse_v1compat_agent_id(Subject) of
                    RecvId ->
                        handle_deliver_authz_broker_dynsub_create_request(
                            Version, App, Object, Subject, CorrData, BrokerId, AgentId, State);
                    _ ->
                        %% NOTE: don't do anything if a delivery callback was called
                        %% for a different than the subject agent
                        Message
                end;
        {#{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.delete">>,
           connection_mode := service,
           correlation_data := CorrData,
           sent_by := AgentId}} ->
                case catch parse_v1compat_agent_id(Subject) of
                    RecvId ->
                        handle_deliver_authz_broker_dynsub_delete_request(
                            Version, App, Object, Subject, CorrData, BrokerId, AgentId, State);
                    _ ->
                        %% NOTE: don't do anything if a delivery callback was called
                        %% for a different than the subject agent
                        Message
                end;
        _ ->
            error_logger:error_msg(
                "Error on deliver: unsupported broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', ",
                [Payload, Properties, mqttgw_id:format_agent_id(RecvId), Mode]),
            create_dynsub_error_response()
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Payload, Properties, mqttgw_id:format_agent_id(RecvId), Mode, T, R]),
            create_dynsub_error_response()
    end.

-spec handle_deliver_authz_broker_dynsub_create_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_authz_broker_dynsub_create_request(
    Version, App, Object, Subject, CorrData, BrokerId, AgentId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    %% Subscribe the agent to the app's topic and send a success response
    Data = #{app => App, object => Object, version => Version},
    create_dynsub(Subject, Data),

    %% Send a multicast event to the application
    send_dynsub_event(
        <<"subscription.create">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),
    %% TODO: remove v1
    send_dynsub_event(
        <<"subscription.create">>, Subject, Data, ?BROKER_V1COMPAT_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    SenderConn = #connection{version=Version, mode=service},
    create_dynsub_response(
        CorrData, BrokerId, SenderConn, AgentId,
        UniqueId, SessionPairId, Time).

-spec handle_deliver_authz_broker_dynsub_delete_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_authz_broker_dynsub_delete_request(
    Version, App, Object, Subject, CorrData, BrokerId, AgentId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    %% Unsubscribe the agent from the app's topic and send a success response
    Data = #{app => App, object => Object, version => Version},
    delete_dynsub(Subject, Data),

    %% Send a multicast event to the application
    send_dynsub_event(
        <<"subscription.delete">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),
    %% TODO: remove v1
    send_dynsub_event(
        <<"subscription.delete">>, Subject, Data, ?BROKER_V1COMPAT_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    SenderConn = #connection{version=Version, mode=service},
    create_dynsub_response(
        CorrData, BrokerId, SenderConn, AgentId,
        UniqueId, SessionPairId, Time).

-spec create_dynsub_response(
    binary(), mqttgw_id:agent_id(), connection(), mqttgw_id:agent_id(),
    binary(), binary(), non_neg_integer())
    -> message().
create_dynsub_response(CorrData, BrokerId, SenderConn, SenderId, UniqueId, SessionPairId, Time) ->
    #message{
        payload = jsx:encode(#{}),
        properties =
            validate_message_properties(
                update_message_properties(
                    #{p_correlation_data => CorrData,
                        p_user_property =>
                        [ {<<"type">>, <<"response">>},
                          {<<"status">>, <<"200">>} ]},
                    SenderConn,
                    SenderId,
                    BrokerId,
                    UniqueId,
                    SessionPairId,
                    Time
                ),
                SenderConn,
                SenderId
            )}.

-spec create_dynsub_error_response() -> message().
create_dynsub_error_response() ->
    #message{payload = jsx:encode(#{issue => 1326}), properties = #{}}.

-spec parse_deliver_broker_request_properties(map()) -> map().
parse_deliver_broker_request_properties(Properties) ->
    #{p_user_property := UserProperties,
      p_correlation_data := CorrData,
      p_response_topic := RespTopic} = Properties,
    {_, Type} = lists:keyfind(<<"type">>, 1, UserProperties),
    {_, Method} = lists:keyfind(<<"method">>, 1, UserProperties),
    {_, ConnVer} = lists:keyfind(<<"connection_version">>, 1, UserProperties),
    {_, ConnMode} = lists:keyfind(<<"connection_mode">>, 1, UserProperties),
    AgentId =
        case lists:keyfind(<<"agent_id">>, 1, UserProperties) of
            {_, ClientId} ->
                parse_agent_id(ClientId);
            _ ->
                %% TODO: remove v1
                {_, AgentLabel} = lists:keyfind(<<"agent_label">>, 1, UserProperties),
                {_, AccountLabel} = lists:keyfind(<<"account_label">>, 1, UserProperties),
                {_, Audience} = lists:keyfind(<<"audience">>, 1, UserProperties),
                #{label => AgentLabel,
                  account_id =>
                    #{label => AccountLabel,
                      audience => Audience}}
        end,
    #{type => Type,
      method => Method,
      connection_mode => parse_v1compat_connection_mode(ConnVer, ConnMode),
      correlation_data => CorrData,
      response_topic => RespTopic,
      sent_by => AgentId}.
%% <<<<< END

-spec handle_deliver_mqtt3(topic(), binary(), mqttgw_id:agent_id(), state())
    -> ok | {ok, list()} | {error, error()}.
handle_deliver_mqtt3(Topic, InputPayload, RecvId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    %% TODO: remove the local state, remove "handle_deliver_authz_config"
    try handle_deliver_authz_config(
            Topic,
            handle_mqtt3_envelope_properties(
                validate_envelope(parse_envelope(InputPayload))),
            RecvId,
            State) of
        InputMessage ->
            handle_deliver_mqtt3_changes(InputMessage, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid message = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, mqttgw_id:format_agent_id(RecvId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_deliver_mqtt3_changes(message(), state()) -> ok | {ok, list()}.
handle_deliver_mqtt3_changes(Message, State) ->
    #message{properties=Properties} = Message,
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    ModifiedMessage = Message#message{
        properties=update_deliver_message_properties(Properties, UniqueId, SessionPairId, Time)},

    {ok, [{payload, envelope(ModifiedMessage)}]}.

-spec handle_deliver_mqtt5(
    topic(), binary(), map(), mqttgw_id:agent_id(), state())
    -> ok | {ok, map()} | {error, error()}.
handle_deliver_mqtt5(Topic, InputPayload, _InputProperties, RecvId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    %% TODO: don't modify message payload on publish (only properties)
    % InputMessage = #message{payload = InputPayload, properties = InputProperties},
    % handle_deliver_mqtt5_changes(Mode, InputMessage).

    %% TODO: remove the local state, remove "handle_deliver_authz_config"
    try handle_deliver_authz_config(
            Topic,
            handle_mqtt3_envelope_properties(
                validate_envelope(parse_envelope(InputPayload))),
            RecvId,
            State) of
        InputMessage ->
            handle_deliver_mqtt5_changes(Mode, InputMessage, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid message = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [InputPayload, mqttgw_id:format_agent_id(RecvId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_deliver_mqtt5_changes(connection_mode(), message(), state())
    -> ok | {ok, map()}.
handle_deliver_mqtt5_changes(_Mode, Message, State) ->
    #message{payload=Payload, properties=Properties} = Message,
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    Changes =
        #{payload => Payload,
          properties => update_deliver_message_properties(
              Properties, UniqueId, SessionPairId, Time)},

    {ok, Changes}.

-spec update_deliver_message_properties(map(), binary(), binary(), non_neg_integer()) -> map().
update_deliver_message_properties(Properties, UniqueId, SessionPairId, Time) ->
    UserProperties0 = maps:from_list(maps:get(p_user_property, Properties, [])),

    %% Additional broker properties
    UserProperties1 =
        UserProperties0#{
            <<"broker_timestamp">> => integer_to_binary(Time)},

    %% Tracking properties
    UserProperties2 =
        update_session_tracking_label_property(
            UniqueId,
            SessionPairId,
            UserProperties1),

    Properties#{p_user_property => maps:to_list(UserProperties2)}.

%% =============================================================================
%% API: Subscribe
%% =============================================================================

-spec handle_subscribe_authz([subscription()], mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_subscribe_authz(Subscriptions, AgentId, State) ->
    handle_subscribe_authz_config(Subscriptions, AgentId, State).

-spec handle_subscribe_authz_config([subscription()], mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_subscribe_authz_config(Subscriptions, AgentId, State) ->
    case State#state.config#config.authz of
        disabled ->
            handle_subscribe_success(Subscriptions, AgentId, State);
        {enabled, _Config} ->
            handle_subscribe_authz_topic(Subscriptions, AgentId, State)
    end.

-spec handle_subscribe_authz_topic([subscription()], mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_subscribe_authz_topic(Subscriptions, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    try [verify_subscribtion(
          Topic,
          mqttgw_id:format_account_id(AgentId),
          mqttgw_id:format_agent_id(AgentId),
          Mode)
        || {Topic, _QoS} <- Subscriptions] of
        _ ->
            handle_subscribe_success(Subscriptions, AgentId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on subscribe: one of the subscriptions = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Subscriptions, mqttgw_id:format_agent_id(AgentId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_subscribe_success([subscription()], mqttgw_id:agent_id(), state())
    -> ok | {error, error()}.
handle_subscribe_success(Topics, AgentId, State) ->
    #state{session=#session{connection=#connection{mode=Mode}}} = State,

    error_logger:info_msg(
        "Agent = '~s' subscribed: mode = '~s', topics = ~p",
        [mqttgw_id:format_agent_id(AgentId), Mode, Topics]),

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
    when (Mode =:= service) or (Mode =:= bridge)
    -> ok;
%% Multicast:
%% <- request(app-from-any): agents/+/api/v1/out/ACCOUNT_ID(ME)
verify_subscribe_topic([<<"agents">>, _, <<"api">>, _, <<"out">>, Me], Me, _AgentId, Mode)
    when (Mode =:= service) or (Mode =:= bridge)
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

-spec handle_broker_start(state()) -> ok.
handle_broker_start(State) ->
    handle_broker_start_stat_config(State).

-spec handle_broker_start_stat_config(state()) -> ok.
handle_broker_start_stat_config(State) ->
    case State#state.config#config.stat of
        enabled ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{
                    id=SessionId,
                    parent_id=ParentSessionId,
                    created_at=Ts},
                config=#config{
                    id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => mqttgw_id:format_agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_CONNECTION,
                BrokerId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
            %% TODO: remove v1
            send_audience_event(
                #{id => mqttgw_id:format_agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_V1COMPAT_CONNECTION,
                BrokerId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
            handle_broker_start_success();
        _ ->
            handle_broker_start_success()
    end.

handle_broker_start_success() ->
    ok.

%% =============================================================================
%% API: Broker Stop
%% =============================================================================

-spec handle_broker_stop(state()) -> ok.
handle_broker_stop(State) ->
    handle_broker_stop_authz_config(State).

-spec handle_broker_stop_authz_config(state()) -> ok.
handle_broker_stop_authz_config(State) ->
    case State#state.config#config.authz of
        {enabled, _Config} ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{id=SessionId, parent_id=ParentSessionId},
                config=#config{id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            erase_dynsubs(?BROKER_CONNECTION, BrokerId, UniqueId, SessionPairId, Time),
            handle_broker_stop_stat_config(State);
        _ ->
            handle_broker_stop_stat_config(State)
    end.

-spec handle_broker_stop_stat_config(state()) -> ok.
handle_broker_stop_stat_config(State) ->
    case State#state.config#config.stat of
        enabled ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{
                    id=SessionId,
                    parent_id=ParentSessionId,
                    created_at=Ts},
                config=#config{
                    id=BrokerId}} = State,
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => mqttgw_id:format_agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_CONNECTION,
                BrokerId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
            %% TODO: remove v1
            send_audience_event(
                #{id => mqttgw_id:format_agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                ?BROKER_V1COMPAT_CONNECTION,
                BrokerId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
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

    %% Create the broker config
    BrokerId = mqttgw_id:read_config(),
    Config =
        #config{
            id=BrokerId,
            authn=mqttgw_authn:read_config(),
            authz=mqttgw_authz:read_config(),
            stat=mqttgw_stat:read_config()},
    mqttgw_state:put(config, Config),

    %% Create the broker session
    Conn = ?BROKER_CONNECTION,
    Time = os:system_time(millisecond),
    Session =
        #session{
            id=make_uuid(),
            parent_id=make_uuid(),
            connection=Conn,
            created_at=Time},
    mqttgw_state:put(BrokerId, Session),

    handle_broker_start(broker_state(Config, Session, Time)),
    ok.

-spec stop() -> ok.
stop() ->
    Config = mqttgw_state:get(config),
    Time = os:system_time(millisecond),
    AgentId = Config#config.id,
    handle_broker_stop(broker_state(Config, mqttgw_state:get(AgentId), Time)).

auth_on_register(
    _Peer, {_MountPoint, Conn} = _SubscriberId, Username,
    Password, CleanSession) ->
    State = broker_initial_state(mqttgw_state:get(config), os:system_time(millisecond)),
    Props = connect_properties_mqtt3(Username),
    case handle_connect(Conn, Password, CleanSession, Props, State) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_register_m5(
    _Peer, {_MountPoint, Conn} = _SubscriberId, _Username,
    Password, CleanSession, Properties) ->
    State = broker_initial_state(mqttgw_state:get(config), os:system_time(millisecond)),
    handle_connect(Conn, Password, CleanSession, Properties, State).

auth_on_publish(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_publish_mqtt3_constraints(
        Topic, Payload, QoS, IsRetain, AgentId, State).

auth_on_publish_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain, Properties) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_publish_mqtt5_constraints(
        Topic, Payload, Properties, QoS, IsRetain, AgentId, State).

on_deliver(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Topic, Payload) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_deliver_mqtt3(Topic, Payload, AgentId, State).

on_deliver_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Topic, Payload, Properties) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_deliver_mqtt5(Topic, Payload, Properties, AgentId, State).

auth_on_subscribe(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    case handle_subscribe_authz(Subscriptions, AgentId, State) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_subscribe_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions, _Properties) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_subscribe_authz(Subscriptions, AgentId, State).

on_client_offline({_MountPoint, Conn} = _SubscriberId) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_disconnect(Conn, AgentId, State).

on_client_gone({_MountPoint, Conn} = _SubscriberId) ->
    AgentId = parse_v1compat_agent_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(AgentId),
        os:system_time(millisecond)),
    handle_disconnect(Conn, AgentId, State).

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec broker_initial_state(config(), non_neg_integer()) -> initial_state().
broker_initial_state(Config, Time) ->
    #initial_state{config=Config, time=Time}.

-spec broker_state(config(), session(), non_neg_integer()) -> state().
broker_state(Config, Session, Time) ->
    #state{config=Config, session=Session, unique_id=make_uuid(), time=Time}.

-spec format_tracking_id(binary(), binary()) -> binary().
format_tracking_id(Label, SessionId) ->
    <<Label/binary, $., SessionId/binary>>.

-spec format_session_id(binary(), binary()) -> binary().
format_session_id(SessionId, ParentSessionId) ->
    <<SessionId/binary, $., ParentSessionId/binary>>.

-spec make_uuid() -> binary().
make_uuid() ->
    uuid:uuid_to_string(uuid:get_v4(), binary_standard).

-spec validate_connection_params({connection(), mqttgw_id:agent_id()})
    -> {connection(), mqttgw_id:agent_id()}.
validate_connection_params({Conn, AgentId}) ->
    {Conn,
     validate_agent_id(AgentId)}.

-spec validate_agent_id(mqttgw_id:agent_id()) -> mqttgw_id:agent_id().
validate_agent_id(Val) ->
    #{label := AgentLabel,
      account_id := #{
          label := AccountLabel,
          audience := Audience}} = Val,

    true = is_binary(AgentLabel),
    true = is_binary(AccountLabel),
    true = is_binary(Audience),

    Val.

-spec format_connection_mode(connection_mode()) -> binary().
format_connection_mode(Mode) ->
    atom_to_binary(Mode, utf8).

-spec parse_connection_mode(binary()) -> connection_mode().
parse_connection_mode(<<"default">>)  -> default;
parse_connection_mode(<<"service">>)  -> service;
parse_connection_mode(<<"observer">>) -> observer;
parse_connection_mode(<<"bridge">>)   -> bridge;
parse_connection_mode(Mode)           -> error({bad_mode, Mode}).

-spec connect_properties_mqtt3(binary()) -> map().
connect_properties_mqtt3(<<"v2::", Mode/binary>>) ->
    UserProperties =
        [{<<"connection_version">>, ?VER_2},
         {<<"connection_mode">>, Mode}],
    #{p_user_property => UserProperties};
connect_properties_mqtt3(_Val) ->
    #{}.

-spec parse_connection_params(binary(), map()) -> {connection(), mqttgw_id:agent_id()}.
parse_connection_params(ClientId, Properties) ->
    UserProperties = maps:from_list(maps:get(p_user_property, Properties, [])),
    case {
        maps:find(<<"connection_version">>, UserProperties),
        maps:find(<<"connection_mode">>, UserProperties)} of
        {{ok, ?VER_2 =Ver}, {ok, Mode}} ->
            {#connection{mode=parse_connection_mode(Mode), version=Ver},
             parse_agent_id(ClientId)};
        _ ->
            %% TODO: remove v1
            %% {#connection{mode=default, version=?VER_2},
            %%  parse_agent_id(ClientId)};
            parse_v1_connection_params(ClientId)
    end.

%% TODO: remove v1
%% START >>>>>
-spec parse_v1_connection_params(binary()) -> {connection(), mqttgw_id:agent_id()}.
parse_v1_connection_params(<<"v1/agents/", R/bits>>) ->
    {#connection{version= ?VER_1, mode=default},
     parse_agent_id(R)};
parse_v1_connection_params(<<"v1/service-agents/", R/bits>>) ->
    {#connection{version= ?VER_1, mode=service},
     parse_agent_id(R)};
parse_v1_connection_params(<<"v1/observer-agents/", R/bits>>) ->
    {#connection{version= ?VER_1, mode=observer},
     parse_agent_id(R)};
parse_v1_connection_params(<<"v1/bridge-agents/", R/bits>>) ->
    {#connection{version= ?VER_1, mode=bridge},
     parse_agent_id(R)};
parse_v1_connection_params(R) ->
    error({bad_mode, [R]}).

-spec parse_v1compat_agent_id(binary()) -> mqttgw_id:agent_id().
parse_v1compat_agent_id(<<"v1/agents/", R/bits>>) ->
    parse_agent_id(R);
parse_v1compat_agent_id(<<"v1/service-agents/", R/bits>>) ->
    parse_agent_id(R);
parse_v1compat_agent_id(<<"v1/observer-agents/", R/bits>>) ->
    parse_agent_id(R);
parse_v1compat_agent_id(<<"v1/bridge-agents/", R/bits>>) ->
    parse_agent_id(R);
parse_v1compat_agent_id(Val) ->
    parse_agent_id(Val).

-spec format_v1compat_connection_mode(binary(), connection_mode()) -> binary().
format_v1compat_connection_mode(?VER_1, default) ->
    <<"agents">>;
format_v1compat_connection_mode(?VER_1, service) ->
    <<"service-agents">>;
format_v1compat_connection_mode(?VER_1, observer) ->
    <<"observer-agents">>;
format_v1compat_connection_mode(?VER_1, bridge) ->
    <<"bridge-agents">>;
format_v1compat_connection_mode(?VER_2, Mode) ->
    format_connection_mode(Mode).

-spec parse_v1compat_connection_mode(binary(), binary()) -> connection_mode().
parse_v1compat_connection_mode(?VER_1, <<"agents">>) ->
    default;
parse_v1compat_connection_mode(?VER_1, <<"service-agents">>) ->
    service;
parse_v1compat_connection_mode(?VER_1, <<"observer-agents">>) ->
    observer;
parse_v1compat_connection_mode(?VER_1, <<"bridge-agents">>) ->
    bridge;
parse_v1compat_connection_mode(?VER_1, Mode) ->
    error({bad_v1mode, Mode});
parse_v1compat_connection_mode(?VER_2, Mode) ->
    parse_connection_mode(Mode).
%% <<<<< END

-spec parse_agent_id(binary()) -> mqttgw_id:agent_id().
parse_agent_id(Val) ->
    parse_agent_label(Val, <<>>).

-spec parse_agent_label(binary(), binary()) -> mqttgw_id:agent_id().
parse_agent_label(<<$., _/bits>>, <<>>) ->
    error(missing_agent_label);
parse_agent_label(<<$., R/bits>>, Acc) ->
    parse_account_label(R, Acc, <<>>);
parse_agent_label(<<C, R/bits>>, Acc) ->
    parse_agent_label(R, <<Acc/bits, C>>);
parse_agent_label(<<>>, Acc) ->
    error({bad_agent_label, [Acc]}).

-spec parse_account_label(binary(), binary(), binary()) -> mqttgw_id:agent_id().
parse_account_label(<<$., _/bits>>, _AgentLabel, <<>>) ->
    error(missing_account_label);
parse_account_label(<<$., R/bits>>, AgentLabel, Acc) ->
    parse_audience(R, AgentLabel, Acc);
parse_account_label(<<C, R/bits>>, AgentLabel, Acc) ->
    parse_account_label(R, AgentLabel, <<Acc/binary, C>>);
parse_account_label(<<>>, AgentLabel, Acc) ->
    error({bad_account_label, [AgentLabel, Acc]}).

-spec parse_audience(binary(), binary(), binary()) -> mqttgw_id:agent_id().
parse_audience(<<>>, _AgentLabel, _AccountLabel) ->
    error(missing_audience);
parse_audience(Audience, AgentLabel, AccountLabel) ->
    #{label => AgentLabel,
      account_id => #{
          label => AccountLabel,
          audience => Audience}}.

% TODO: remove v1
% -spec validate_authn_properties(map()) -> map().
% validate_authn_properties(Properties) ->
%     %% TODO: remove v1: agent_label, account_label, audience properties
%     %% TODO: add validation of 'agent_id' property
%     _ = validate_agent_label_property(Properties),
%     _ = validate_account_label_property(Properties),
%     _ = validate_audience_property(Properties),
%     Properties.

% -spec validate_agent_label_property(map()) -> binary().
% validate_agent_label_property(#{<<"agent_label">> := Val}) when is_binary(Val) ->
%     Val;
% validate_agent_label_property(#{<<"agent_label">> := Val}) ->
%     error({bad_agent_label, Val});
% validate_agent_label_property(_) ->
%     error(missing_agent_label).

% -spec validate_account_label_property(map()) -> binary().
% validate_account_label_property(#{<<"account_label">> := Val}) when is_binary(Val) ->
%     Val;
% validate_account_label_property(#{<<"account_label">> := Val}) ->
%     error({bad_account_label, Val});
% validate_account_label_property(_) ->
%     error(missing_account_label).

% -spec validate_audience_property(map()) -> binary().
% validate_audience_property(#{<<"audience">> := Val}) when is_binary(Val) ->
%     Val;
% validate_audience_property(#{<<"audience">> := Val}) ->
%     error({bad_audience, Val});
% validate_audience_property(_) ->
%     error(missing_audience).

-spec validate_envelope(message()) -> message().
validate_envelope(Val) ->
    #message{
        payload=Payload,
        properties=Properties} = Val,

    true = is_binary(Payload),
    true = is_map(Properties),
    Val.

-spec parse_envelope(binary()) -> message().
parse_envelope(Message) ->
    Envelope = jsx:decode(Message, [return_maps]),
    Payload = maps:get(<<"payload">>, Envelope),
    Properties = maps:get(<<"properties">>, Envelope, #{}),
    #message{payload=Payload, properties=Properties}.

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

    %% TODO: remove the local state
    %% START >>>>>
    %% We preserve (duplicate) information about the dynamic subscription to a local state
    %% to be able to send an 'subscription.delete' event in the future.
    %% This redundant behavior hopefully will be unnecessary with resolving of the 'issue:1326'.
    %% https://github.com/vernemq/vernemq/issues/1326
    mqttgw_dynsubstate:put(Subject, Data),
    %% <<<<< END

    error_logger:info_msg(
        "Dynamic subscription: ~p has been created "
        "for the subject = '~s'",
        [Data, Subject]),

    ok.

-spec delete_dynsub(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
delete_dynsub(Subject, Data) ->
    Topic = authz_subscription_topic(Data),
    mqttgw_broker:unsubscribe(Subject, [Topic]),

    %% TODO: remove the local state
    %% START >>>>>
    %% We remove preserved information about the dynamic subscription from a local state.
    %% This redundant behavior hopefully will be unnecessary with resolving of the 'issue:1326'.
    %% https://github.com/vernemq/vernemq/issues/1326
    mqttgw_dynsubstate:remove(Subject, Data),
    %% <<<<< END

    error_logger:info_msg(
        "Dynamic subscription: ~p has been deleted "
        "for the subject = '~s'",
        [Data, Subject]),

    ok.

-spec delete_client_dynsubs(
    mqttgw_dynsub:subject(), connection(), mqttgw_id:agent_id(),
    binary(), binary(), non_neg_integer())
    -> ok.
delete_client_dynsubs(Subject, BrokerConn, BrokerId, UniqueId, SessionPairId, Time) ->
    %% TODO: remove the local state
    %% NOTE: In the case when a dynamic subscription was created for an offline client,
    %% even though it later connects with 'clean_session=false' flushing subscriptions
    %% in the internal state of the broker instance,
    %% the event 'subscription.delete' will be sent.
    %% START >>>>>
    %% We read preserved information about the dynamic subscription from a local state
    %% because the same information in the internal state of the broker is already flushed.
    %% This redundant behavior hopefully will be unnecessary with resolving of the 'issue:1326'.
    %% https://github.com/vernemq/vernemq/issues/1326
    DynSubL = mqttgw_dynsubstate:get(Subject),
    %% <<<<< END
    %% TODO: uncomment the line bellow
    % DynSubL = mqttgw_dynsub:list(Subject),

    %% Send a multicast event to the application
    [send_dynsub_event(
        <<"subscription.delete">>, Subject, Data, BrokerConn, BrokerId,
        UniqueId, SessionPairId, Time)
     || Data <- DynSubL],
    %% TODO: remove v1
    [send_dynsub_event(
        <<"subscription.delete">>, Subject, Data, ?BROKER_V1COMPAT_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time)
     || Data <- DynSubL],

    %% Remove subscriptions
    [delete_dynsub(Subject, Data) || Data  <- DynSubL],

    ok.

-spec erase_dynsubs(
    connection(), mqttgw_id:agent_id(), binary(), binary(), non_neg_integer())
    -> ok.
erase_dynsubs(BrokerConn, BrokerId, UniqueId, SessionPairId, Time) ->
    [delete_client_dynsubs(Subject, BrokerConn, BrokerId, UniqueId, SessionPairId, Time)
     || Subject <- mqttgw_broker:list_connections()],
    ok.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

% -spec send_dynsub_response(
%     binary(), binary(), binary(), mqttgw_id:agent_id(),
%     connection(), mqttgw_id:agent_id(), binary(), binary(), non_neg_integer())
%     -> ok.
% send_dynsub_response(
%     App, CorrData, RespTopic, BrokerId,
%     SenderConn, SenderId, UniqueId, SessionPairId, Time) ->
%     #connection{mode=Mode} = SenderConn,

%     QoS = 1,
%     try mqttgw_broker:publish(
%         validate_dynsub_response_topic(binary:split(RespTopic, <<$/>>, [global]), App),
%         envelope(
%             #message{
%                 payload = jsx:encode(#{}),
%                 properties =
%                     validate_message_properties(
%                         update_message_properties(
%                             #{p_correlation_data => CorrData,
%                               p_user_property =>
%                                 [ {<<"type">>, <<"response">>},
%                                   {<<"status">>, <<"200">>} ]},
%                             SenderConn,
%                             SenderId,
%                             BrokerId,
%                             UniqueId,
%                             SessionPairId,
%                             Time
%                         ),
%                         SenderConn,
%                         SenderId
%                     )}),
%         QoS) of
%         _ ->
%             ok
%     catch
%         T:R ->
%             error_logger:error_msg(
%                 "Error sending subscription success response to = '~s' "
%                 "from the agent = '~s' using mode = '~s' "
%                 "by the broker agent = '~s', "
%                 "exception_type = ~p, exception_reason = ~p",
%                 [RespTopic, mqttgw_id:format_agent_id(SenderId), Mode,
%                  mqttgw_id:format_agent_id(BrokerId), T, R]),
%             {error, #{reason_code => impl_specific_error}}
%     end.

-spec send_dynsub_event(
    binary(), mqttgw_dynsub:subject(), mqttgw_dynsub:data(),
    connection(), mqttgw_id:agent_id(), binary(), binary(), non_neg_integer())
    -> ok.
send_dynsub_event(Label, Subject, Data, SenderConn, SenderId, UniqueId, SessionPairId, Time) ->
    QoS = 1,
    #{app := App, object := Object} = Data,
    try mqttgw_broker:publish(
        dynsub_event_topic(SenderConn, App, SenderId),
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
                            SenderConn,
                            SenderId,
                            SenderId,
                            UniqueId,
                            SessionPairId,
                            Time
                        ),
                        SenderConn,
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
                [App, mqttgw_id:format_agent_id(SenderId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec send_audience_event(
    map(), list(), connection(), mqttgw_id:agent_id(), mqttgw_id:agent_id(),
    binary(), binary(), non_neg_integer())
    -> ok.
send_audience_event(
    Payload, UserProperties, SenderConn, SenderId, AgentId, UniqueId, SessionPairId, Time) ->
    Topic = audience_event_topic(SenderConn, AgentId, SenderId),
    QoS = 1,
    try mqttgw_broker:publish(
        Topic,
        envelope(
            #message{
                payload = jsx:encode(Payload),
                properties =
                    validate_message_properties(
                        update_message_properties(
                            #{p_user_property => UserProperties},
                            SenderConn,
                            SenderId,
                            SenderId,
                            UniqueId,
                            SessionPairId,
                            Time
                        ),
                        SenderConn,
                        SenderId
                    )}),
        QoS) of
        _ ->
            ok
    catch
        T:R ->
            error_logger:error_msg(
                "Error sending audience event: '~p', topic = `~p` "
                "by the broker agent = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [UserProperties, Topic, mqttgw_id:format_agent_id(SenderId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec audience_event_topic(connection(), mqttgw_id:agent_id(), mqttgw_id:agent_id()) -> topic().
audience_event_topic(Conn, AgentId, BrokerId) ->
    #connection{version=Ver} = Conn,
    [<<"apps">>, mqttgw_id:format_account_id(BrokerId),
     <<"api">>, Ver, <<"audiences">>, mqttgw_id:audience(AgentId), <<"events">>].

-spec dynsub_event_topic(connection(), binary(), mqttgw_id:agent_id()) -> topic().
dynsub_event_topic(Conn, App, BrokerId) ->
    #connection{version=Ver} = Conn,
    [<<"agents">>, mqttgw_id:format_agent_id(BrokerId),
     <<"api">>, Ver, <<"out">>, App].

-spec authz_subscription_topic(mqttgw_dynsub:data()) -> topic().
authz_subscription_topic(Data) ->
    #{app := App,
      object := Object,
      version := Version} = Data,
    [<<"apps">>, App, <<"api">>, Version | Object].

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

% -spec validate_dynsub_response_topic(topic(), binary()) -> topic().
% validate_dynsub_response_topic([<<"agents">>, _, <<"api">>, _, <<"in">>, App] = Topic, App) ->
%     Topic;
% validate_dynsub_response_topic(Topic, App) ->
%     error({nomatch_app_in_broker_response_topic, Topic, App}).

% -spec parse_broker_request_properties(map()) -> map().
% parse_broker_request_properties(Properties) ->
%     #{p_user_property := UserProperties,
%       p_correlation_data := CorrData,
%       p_response_topic := RespTopic} = Properties,
%     {_, Type} = lists:keyfind(<<"type">>, 1, UserProperties),
%     {_, Method} = lists:keyfind(<<"method">>, 1, UserProperties),
%     #{type => Type,
%       method => Method,
%       correlation_data => CorrData,
%       response_topic => RespTopic}.

-spec binary_join([binary()], binary()) -> binary().
binary_join([H], _) -> H;
binary_join([H|T], Sep) ->
    lists:foldl(
        fun(Val, Acc) ->
            <<Acc/binary, Sep/binary, Val/binary>>
        end, H, T);
binary_join([], _)  -> <<>>.

%% =============================================================================
%% Tests
%% =============================================================================

-ifdef(TEST).

-define(TYPE_TEST_PROP, {<<"type">>, <<"_test">>}).

mode_t() ->
    ?LET(
        Index,
        choose(1, 4),
        lists:nth(Index, [default, service, observer, bridge])).

client_id_t() ->
    ?LET(
        {AgentLabel, AccountLabel, Audience},
        {label_t(), label_t(), label_t()},
        <<AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>).

subscriber_id_t() ->
    ?LET(
        {MountPoint, AgentId},
        {string(), client_id_t()},
        {MountPoint, AgentId}).

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

%% TODO: remove v1
%% START >>>>>
v1_version_mode_t() ->
    ?LET(
        Index,
        choose(1, 4),
        lists:nth(Index,
            [{?VER_1, <<"agents">>},
             {?VER_1, <<"bridge-agents">>},
             {?VER_1, <<"observer-agents">>},
             {?VER_1, <<"service-agents">>}])).

v1_client_id_t() ->
    ?LET(
        {{Version, Mode}, AgentLabel, AccountLabel, Audience},
        {v1_version_mode_t(), label_t(), label_t(), label_t()},
        <<Version/binary, $/, Mode/binary, $/,
          AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>).

v1_subscriber_id_t() ->
    ?LET(
        {MountPoint, AgentId},
        {string(), v1_client_id_t()},
        {MountPoint, AgentId}).

prop_onconnect_v1() ->
    ?FORALL(
        {SubscriberId, Password},
        {v1_subscriber_id_t(), binary_utf8_t()},
        begin
            CleanSession = minimal_constraint(clean_session),

            Time = 0,
            BrokerId = make_sample_broker_id(),
            Conn = element(2, SubscriberId),
            Config = make_sample_config(disabled, disabled, disabled),
            State = broker_initial_state(Config, Time),

            %% NOTE: we use it to read the broker config and store agent's initial state
            mqttgw_state:new(),
            mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, BrokerId)),
            mqttgw_state:put(BrokerId, make_sample_broker_session()),

            ok = handle_connect(Conn, Password, CleanSession, #{}, State),
            true
        end).

v1_authz_onconnect_test_() ->
    CleanSession = minimal_constraint(clean_session),
    Time = 0,

    AgentLabel = <<"foo">>,
    AccountLabel = <<"bar">>,
    SvcAud = BrokerAud = <<"svc.example.org">>,
    SvcAccountId = #{label => AccountLabel, audience => SvcAud},
    UsrAud = <<"usr.example.net">>,

    #{password := SvcPassword,
      config := SvcAuthnConfig} =
        make_sample_password(<<"bar">>, SvcAud, <<"svc.example.org">>),
    #{password := UsrPassword,
      config := UsrAuthnConfig} =
        make_sample_password(<<"bar">>, UsrAud, <<"iam.svc.example.net">>),
    #{id := BrokerId,
      config := AuthzConfig} = make_sample_broker_config(BrokerAud, [SvcAccountId]),

    Test = [
        { "usr: allowed",
          [default], UsrAud, UsrPassword,
          ok },
        { "usr: forbidden",
          [service, observer, bridge], UsrAud, UsrPassword,
          {error, #{reason_code => not_authorized}} },
        { "svc: allowed",
          [default, service, observer, bridge], SvcAud, SvcPassword,
          ok }
    ],

    %% NOTE: we use it to read the broker config and store agent's initial state
    mqttgw_state:new(),
    mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, BrokerId)),
    mqttgw_state:put(BrokerId, make_sample_broker_session()),

    %% 1 - authn: enabled, authz: disabled
    %% Anyone can connect in any mode when authz is dissabled
    State1 =
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                disabled,
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId =
                v1_make_sample_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER_1),
            Result = handle_connect(ClientId, Password, CleanSession, #{}, State1),
            {Desc, ?_assertEqual(ok, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, _Expect} <- Test],

    %% 2 - authn: enabled, authz: enabled
    %% User accounts can connect only in 'default' mode
    %% Service accounts can connect in any mode
    State2 =
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                {enabled, AuthzConfig},
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId =
                v1_make_sample_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER_1),
            Result = handle_connect(ClientId, Password, CleanSession, #{}, State2),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test],

    %% 3 - authn: disabled, authz: enabled
    State3 =
        broker_initial_state(
            make_sample_config(
                disabled,
                {enabled, AuthzConfig},
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId =
                v1_make_sample_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER_1),
            Result = handle_connect(ClientId, Password, CleanSession, #{}, State3),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test].
% <<<<< END

prop_onconnect() ->
    ?FORALL(
        {Mode, SubscriberId, Password},
        {mode_t(), subscriber_id_t(), binary_utf8_t()},
        begin
            CleanSession = minimal_constraint(clean_session),

            Time = 0,
            BrokerId = make_sample_broker_id(),
            Conn = element(2, SubscriberId),
            Config = make_sample_config(disabled, disabled, disabled),
            State = broker_initial_state(Config, Time),

            %% NOTE: we use it to read the broker config and store agent's initial state
            mqttgw_state:new(),
            mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, BrokerId)),
            mqttgw_state:put(BrokerId, make_sample_broker_session()),

            Props = make_sample_connection_properties(Mode),
            ok = handle_connect(Conn, Password, CleanSession, Props, State),
            true
        end).

authz_onconnect_test_() ->
    CleanSession = minimal_constraint(clean_session),
    Time = 0,

    AgentLabel = <<"foo">>,
    AccountLabel = <<"bar">>,
    SvcAud = BrokerAud = <<"svc.example.org">>,
    SvcAccountId = #{label => AccountLabel, audience => SvcAud},
    UsrAud = <<"usr.example.net">>,

    #{password := SvcPassword,
      config := SvcAuthnConfig} =
        make_sample_password(<<"bar">>, SvcAud, <<"svc.example.org">>),
    #{password := UsrPassword,
      config := UsrAuthnConfig} =
        make_sample_password(<<"bar">>, UsrAud, <<"iam.svc.example.net">>),
    #{id := BrokerId,
      config := AuthzConfig} = make_sample_broker_config(BrokerAud, [SvcAccountId]),

    Test = [
        { "usr: allowed",
          [default], UsrAud, UsrPassword,
          ok },
        { "usr: forbidden",
          [service, observer, bridge], UsrAud, UsrPassword,
          {error, #{reason_code => not_authorized}} },
        { "svc: allowed",
          [default, service, observer, bridge], SvcAud, SvcPassword,
          ok }
    ],

    %% NOTE: we use it to read the broker config and store agent's initial state
    mqttgw_state:new(),
    mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, BrokerId)),
    mqttgw_state:put(BrokerId, make_sample_broker_session()),

    %% 1 - authn: enabled, authz: disabled
    %% Anyone can connect in any mode when authz is dissabled
    State1 =
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                disabled,
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId = <<AgentLabel/binary, $., AccountLabel/binary, $., Aud/binary>>,
            Props = make_sample_connection_properties(Mode),
            Result = handle_connect(ClientId, Password, CleanSession, Props, State1),
            {Desc, ?_assertEqual(ok, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, _Expect} <- Test],

    %% 2 - authn: enabled, authz: enabled
    %% User accounts can connect only in 'default' mode
    %% Service accounts can connect in any mode
    State2 =
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                {enabled, AuthzConfig},
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId = <<AgentLabel/binary, $., AccountLabel/binary, $., Aud/binary>>,
            Props = make_sample_connection_properties(Mode),
            Result = handle_connect(ClientId, Password, CleanSession, Props, State2),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test],

    %% 3 - authn: disabled, authz: enabled
    State3 =
        broker_initial_state(
            make_sample_config(
                disabled,
                {enabled, AuthzConfig},
                disabled,
                BrokerId),
            Time),
    [begin
        [begin
            ClientId = <<AgentLabel/binary, $., AccountLabel/binary, $., Aud/binary>>,
            Props = make_sample_connection_properties(Mode),
            Result = handle_connect(ClientId, Password, CleanSession, Props, State3),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test].

message_connect_constraints_test_() ->
    AnyMode = [default, service, observer, bridge],
    TrustedMode = [service, observer, bridge],
    NonTrustedMode = AnyMode -- TrustedMode,
    AnyCleanSession = [false, true],

    Test = [
        {"trusted: any clean_session", AnyCleanSession, TrustedMode, ok},
        {"nontrusted: w/ clean_session", [true], NonTrustedMode, ok},
        {"nontrusted: w/o clean_session", [false], NonTrustedMode, error}
    ],

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
        {Mode, _Username, SubscriberId, Topic, Payload},
        {mode_t(), binary_utf8_t(), subscriber_id_t(), publish_topic_t(), binary_utf8_t()},
        begin
            QoS = minimal_constraint(qos),
            IsRetain = minimal_constraint(retain),
            BrokerId = make_sample_broker_id(),
            Time = 0,
            TimeB = TimeDiffB = integer_to_binary(Time),

            #{label := AgentLabel,
              account_id := #{
                label := AccountLabel,
                audience := Audience}} = AgentId = parse_agent_id(element(2, SubscriberId)),
            State = make_sample_broker_state(
                make_sample_config(disabled, disabled, disabled, BrokerId),
                make_sample_session(Mode),
                Time),
            ExpectedBrokerL =
                [ {<<"broker_id">>, mqttgw_id:format_agent_id(BrokerId)},
                  %% TODO: remove v1
                  {<<"broker_agent_label">>, mqttgw_id:label(BrokerId)},
                  {<<"broker_account_label">>, mqttgw_id:account_label(BrokerId)},
                  {<<"broker_audience">>, mqttgw_id:audience(BrokerId)},
                  %%
                  {<<"broker_processing_timestamp">>, TimeB},
                  {<<"broker_initial_processing_timestamp">>, TimeB} ],
            ExpectedConnectionL =
                [ {<<"connection_version">>, ?VER_2},
                  {<<"connection_mode">>, format_connection_mode(Mode)} ],
            ExpectedAuthnUserL =
                [ {<<"agent_id">>, mqttgw_id:format_agent_id(AgentId)},
                  %% TODO: remove v1
                  {<<"agent_label">>, AgentLabel},
                  {<<"account_label">>, AccountLabel},
                  {<<"audience">>, Audience} ],
            ExpectedAuthnProperties = #{p_user_property => [?TYPE_TEST_PROP | ExpectedAuthnUserL]},
            ExpectedTimeL = [
                {<<"local_initial_timediff">>, TimeDiffB}],
            SessionTrackingL =
                [ {<<"tracking_id">>, make_sample_tracking_id()},
                  {<<"session_tracking_label">>, make_sample_tracking_label()} ],
            ExpectedUserL = [
                ?TYPE_TEST_PROP
                | ExpectedAuthnUserL ++ ExpectedConnectionL ++ ExpectedBrokerL ++ SessionTrackingL],
            ExpectedProperties = fun
                (default) -> #{p_user_property => ExpectedUserL ++ ExpectedTimeL};
                (_) -> #{p_user_property => ExpectedUserL}
            end,

            %% MQTT 5
            begin
                InputProperties =
                    case Mode of
                        M5 when (M5 =:= default) or (M5 =:= service) or (M5 =:= observer) ->
                            Props = #{p_user_property => [?TYPE_TEST_PROP]},
                            add_local_timestamp(Mode, Time, Props);
                        bridge ->
                            ExpectedAuthnProperties
                    end,

                {ok, Modifiers} =
                    handle_publish_mqtt5_constraints(
                        Topic, Payload, InputProperties, QoS, IsRetain,
                        AgentId, State),

                %% TODO: don't modify message payload on publish (only properties)
                %% InputPayload = maps:get(payload, Modifiers),
                %% OutputUserProperties = maps:get(user_property, Modifiers),
                %% lists:usort(OutputUserProperties) == lists:usort(ExpectedUserL)
                ExpectedCompatMessage3 =
                    envelope(#message{payload = Payload, properties = ExpectedProperties(Mode)}),
                ExpectedCompatMessage3 = maps:get(payload, Modifiers),
                [] = maps:get(p_user_property, maps:get(properties, Modifiers))
            end,

            % MQTT 3
            begin
                InputMessage3 =
                    case Mode of
                        M3 when (M3 =:= default) or (M3 =:= service) or (M3 =:= observer) ->
                            InitProps3 = #{p_user_property => [?TYPE_TEST_PROP]},
                            envelope(#message{
                                payload=Payload,
                                properties=add_local_timestamp(Mode, Time, InitProps3)});
                        bridge ->
                            envelope(#message{
                                payload = Payload,
                                properties=#{p_user_property => ExpectedUserL}})
                    end,
                ExpectedMessage3 =
                    envelope(#message{payload = Payload, properties = ExpectedProperties(Mode)}),

                {ok, Modifiers3} =
                    handle_publish_mqtt3_constraints(
                        Topic, InputMessage3, QoS, IsRetain,
                        AgentId, State),
                {_, ExpectedMessage3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

bridge_missing_properties_onpublish_test_() ->
    % QoS = minimal_constraint(qos),
    % IsRetain = minimal_constraint(retain),
    AgentId =
        make_sample_agent_id(<<"foo">>, <<"bar">>, <<"svc.example.org">>),
    BrokerId = make_sample_broker_id(),
    Time = 0,
    State = make_sample_broker_state(
        make_sample_config(disabled, disabled, disabled, BrokerId),
        make_sample_session(bridge),
        Time),

    %% TODO: add validation of 'agent_id' property
    Test =
        [{"missing properties", #{}},
         {"missing agent_label", #{<<"account_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing account_label", #{<<"agent_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing audience", #{<<"agent_label">> => <<>>, <<"account_label">> => <<>>}}],

    [begin
        Message = jsx:encode(#{payload => <<>>, properties => Properties}),
        Expect = {error, #{reason_code => impl_specific_error}},

        [{Desc, ?_assertEqual(Expect, handle_publish_mqtt5([], Message, #{}, AgentId, State))},
         {Desc, ?_assertEqual(Expect, handle_publish_mqtt3([], Message, AgentId, State))}]
     end || {Desc, Properties} <- Test].

authz_onpublish_test_() ->
    Time = 0,
    BrokerId = make_sample_broker_id(<<"aud">>),
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, {enabled, ignore}, disabled, BrokerId),
            make_sample_session(Mode),
            Time)
    end,

    %% Broadcast:
    %% -> event(app-to-any): apps/ACCOUNT_ID(ME)/api/v1/BROADCAST_URI
    %% Multicast:
    %% -> request(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
    %% -> event(one-to-app): agents/AGENT_ID(ME)/api/v1/out/ACCOUNT_ID
    %% Unicast:
    %% -> request(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
    %% -> response(one-to-one): agents/AGENT_ID/api/v1/in/ACCOUNT_ID(ME)
    Broadcast = fun(AgentId) ->
        [<<"apps">>, mqttgw_id:format_account_id(AgentId), <<"api">>, ?VER_2, <<>>]
    end,
    Multicast = fun(AgentId) ->
        [<<"agents">>, mqttgw_id:format_agent_id(AgentId), <<"api">>, ?VER_2, <<"out">>, <<>>]
    end,
    Unicast = fun(AgentId) ->
        [<<"agents">>, <<>>, <<"api">>, ?VER_2, <<"in">>, mqttgw_id:format_account_id(AgentId)]
    end,

    Test = [
        {"usr: broadcast", Broadcast, [default], error},
        {"usr: multicast", Multicast, [default], ok},
        {"usr: unicast", Unicast, [default], error},
        {"svc: broadcast", Broadcast, [service, observer, bridge], ok},
        {"svc: multicast", Multicast, [service, observer, bridge], ok},
        {"svc: unicast", Unicast, [service, observer, bridge], ok}
    ],

    [begin
        [begin
            Message = make_sample_message_bridgecompat(Mode, Time),
            AgentId = make_sample_agent_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>),
            Result =
                case handle_publish_authz(TopicFn(AgentId), Message, AgentId, State(Mode)) of
                    ok -> ok;
                    {error, _} -> error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, TopicFn, Modes, Expect} <- Test].

message_publish_constraints_test_() ->
    AnyMode = [default, service, observer, bridge],
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

message_properties_required_test_() ->
    Time = 0,
    BrokerId = make_sample_broker_id(),
    AgentId =
        make_sample_agent_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>),
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, disabled, disabled, BrokerId),
            make_sample_session(Mode),
            Time)
    end,

    ResponseTopic = fun() ->
        <<"agents/", (mqttgw_id:format_agent_id(AgentId))/binary, "/api/v1/in/baz.aud.example.org">>
    end,
    BadResponseTopic = fun() ->
        <<"agents/another.bar.aud.example.org/api/v1/in/baz.aud.example.org">>
    end,

    AnyMode = [default, service, observer, bridge],
    ServiceMode = [service],
    NonServiceMode = AnyMode -- ServiceMode,

    Test = [
        { "type: no (event)",
          AnyMode,
          #{p_user_property => [{<<"label">>, <<"test">>}]},
          ok },
        { "type: some",
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
          AnyMode, #{p_user_property => [?TYPE_TEST_PROP, {1, <<"num">>}]},
          error },
        { "user property value: number",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"num">>, 1}]},
          error }
    ],

    [begin
        [begin
            %% NOTE: 'local_initial_timediff' is added here when needed
            Message = make_sample_message_bridgecompat(Mode, Time, <<>>, Props),
            Result =
                try handle_message_properties(Message, AgentId, BrokerId, State(Mode)) of
                    _ ->
                        ok
                catch
                    _:_ ->
                        error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Props, Expect} <- Test].

message_properties_optional_test_() ->
    Time0 = 3,
    Time0B = integer_to_binary(Time0),
    Time1 = 5,
    Time1B = integer_to_binary(Time1),
    TimeDiff = Time1 - Time0,
    TimeDiffB = integer_to_binary(TimeDiff),
    BrokerId = make_sample_broker_id(),
    AgentId =
        make_sample_agent_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>),
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, disabled, disabled, BrokerId),
            make_sample_session(Mode),
            Time1)
    end,
    AnyMode = [default, service, observer, bridge],
    % TrustedMode = [service, observer, bridge],
    % NonTrustedMode = AnyMode -- TrustedMode,

    Test = [
        { "unset: broker_initial_processing_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP]},
          [{<<"broker_processing_timestamp">>, Time1B},
           {<<"broker_initial_processing_timestamp">>, Time1B}],
          ok },
        { "set: broker_initial_processing_timestamp",
          AnyMode,
          #{p_user_property =>
            [?TYPE_TEST_PROP,
             {<<"broker_initial_processing_timestamp">>, Time0B}]},
          [?TYPE_TEST_PROP,
           {<<"broker_processing_timestamp">>, Time1B},
           {<<"broker_initial_processing_timestamp">>, Time0B}],
          ok },
        { "unset: timestamp, local_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP]},
          [],
          ok },
        { "set: timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"timestamp">>, Time0B}]},
          [?TYPE_TEST_PROP, {<<"timestamp">>, Time0B}, {<<"initial_timestamp">>, Time0B}],
          ok },
        { "set: timestamp, initial_timestamp",
          AnyMode,
          #{p_user_property =>
            [?TYPE_TEST_PROP,
             {<<"timestamp">>, Time1B},
             {<<"initial_timestamp">>, Time0B}]},
          [{<<"timestamp">>, Time1B}, {<<"initial_timestamp">>, Time0B}],
          ok },
        { "set: initial_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"initial_timestamp">>, Time0B}]},
          [{<<"initial_timestamp">>, Time0B}],
          ok },
        { "set: local_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"local_timestamp">>, Time0B}]},
          [{<<"local_initial_timediff">>, TimeDiffB}],
          ok },
        { "set: local_timestamp, local_initial_timediff",
          AnyMode,
          #{p_user_property =>
            [?TYPE_TEST_PROP,
             {<<"local_timestamp">>, Time0B},
             {<<"local_initial_timediff">>, TimeDiffB}]},
          [{<<"local_initial_timediff">>, TimeDiffB}],
          ok },
        { "set: local_initial_timediff",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"local_initial_timediff">>, TimeDiffB}]},
          [{<<"local_initial_timediff">>, TimeDiffB}],
          ok }
    ],

    [begin
        [begin
            Message = make_sample_message_bridgecompat(Mode, Time0, <<>>, InProps),
            Result =
                try handle_message_properties(Message, AgentId, BrokerId, State(Mode)) of
                    M ->
                        UserProperties = maps:get(p_user_property, M#message.properties),
                        IsPropMatch =
                            lists:all(
                                fun({Key, Val}) ->
                                    case lists:keyfind(Key, 1, UserProperties) of
                                        {_, OutVal} -> Val =:= OutVal;
                                        _ -> false
                                    end
                                end,
                                OutUserProps),
                        case IsPropMatch of true -> ok; _ -> error end
                catch
                    _:_ ->
                        error
                end,
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, InProps, OutUserProps, Expect} <- Test].

prop_ondeliver() ->
    ?FORALL(
        {Mode, _Username, SubscriberId, Topic, Payload},
        {mode_t(), binary_utf8_t(), subscriber_id_t(),
         publish_topic_t(), binary_utf8_t()},
        begin
            BrokerId = make_sample_broker_id(),
            Time = 0,
            #{label := AgentLabel,
              account_id := #{
                label := AccountLabel,
                audience := Audience}} = AgentId = parse_agent_id(element(2, SubscriberId)),
            ExpectedAuthnUserL =
                #{<<"agent_id">> => mqttgw_id:format_agent_id(AgentId),
                  %% TODO: remove v1
                  <<"agent_label">> => AgentLabel,
                  <<"account_label">> => AccountLabel,
                  <<"audience">> => Audience},
            ExpectedBrokerL =
                #{<<"broker_timestamp">> => integer_to_binary(Time)},
            ExpectedSessionTrackingL =
                #{<<"tracking_id">> => make_sample_tracking_id(),
                  <<"session_tracking_label">> => make_sample_tracking_label()},
            ExpectedProperties =
                maps:merge(
                    maps:merge(ExpectedAuthnUserL, ExpectedBrokerL),
                    ExpectedSessionTrackingL),
            InputProperties = ExpectedAuthnUserL,
            InputPayload = jsx:encode(#{payload => Payload, properties => InputProperties}),

            State = make_sample_broker_state(
                make_sample_config(disabled, disabled, disabled, BrokerId),
                make_sample_session(Mode),
                Time),

            %% MQTT 5
            begin
                {ok, Modifiers} =
                    handle_deliver_mqtt5(Topic, InputPayload, #{}, AgentId, State),
                Payload = maps:get(payload, Modifiers)
            end,

            %% MQTT 3
            begin
                ExpectedPayload3 =
                    jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
                {ok, Modifiers3} =
                    handle_deliver_mqtt3(Topic, InputPayload, AgentId, State),
                {_, ExpectedPayload3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

prop_onsubscribe() ->
    ?FORALL(
        {Mode, _Username, SubscriberId, Subscription},
        {mode_t(), binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        begin
            Time = 0,
            BrokerId = make_sample_broker_id(),
            AgentId = parse_agent_id(element(2, SubscriberId)),
            State = make_sample_broker_state(
                make_sample_config(disabled, disabled, disabled, BrokerId),
                make_sample_session(Mode),
                Time),

            ok =:= handle_subscribe_authz(Subscription, AgentId, State)
        end).

authz_onsubscribe_test_() ->
    Time = 0,
    BrokerId = make_sample_broker_id(),

    %% Broadcast:
    %% <- event(any-from-app): apps/ACCOUNT_ID/api/v1/BROADCAST_URI
    %% Multicast:
    %% <- request(app-from-any): agents/+/api/v1/out/ACCOUNT_ID(ME)
    %% Unicast:
    %% <- request(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
    %% <- request(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
    %% <- response(one-from-one): agents/AGENT_ID(ME)/api/v1/in/ACCOUNT_ID
    %% <- response(one-from-any): agents/AGENT_ID(ME)/api/v1/in/+
    Broadcast = fun(_AgentId) ->
        [<<"apps">>, <<>>, <<"api">>, ?VER_2, <<>>]
    end,
    Multicast = fun(AgentId) ->
        [<<"agents">>, <<$+>>, <<"api">>, ?VER_2, <<"out">>, mqttgw_id:format_account_id(AgentId)]
    end,
    Unicast = fun(AgentId) ->
        [<<"agents">>, mqttgw_id:format_agent_id(AgentId), <<"api">>, ?VER_2, <<"in">>, <<$+>>]
    end,
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, {enabled, ignore}, disabled, BrokerId),
            make_sample_session(Mode),
            Time)
    end,

    Test = [
        {"usr: broadcast", Broadcast, [default], {error, #{reason_code => not_authorized}}},
        {"usr: multicast", Multicast, [default], {error, #{reason_code => not_authorized}}},
        {"usr: unicast", Unicast, [default], ok},
        {"svc: broadcast", Broadcast, [service, observer, bridge], ok},
        {"svc: multicast", Multicast, [service, observer, bridge], ok},
        {"svc: unicast", Unicast, [service, observer, bridge], ok}
    ],

    [begin
        [begin
            AgentId = make_sample_agent_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>),
            SubscriptionStd = [{TopicFn(AgentId), 0}],
            SubscriptionShared = [{[<<"$share">>, <<"g">> | TopicFn(AgentId)], 0}],
            ResultStd = handle_subscribe_authz(SubscriptionStd, AgentId, State(Mode)),
            ResultShared = handle_subscribe_authz(SubscriptionShared, AgentId, State(Mode)),
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

make_sample_config(Authn, Authz, Stat) ->
    make_sample_config(Authn, Authz, Stat, make_sample_broker_id()).

make_sample_config(Authn, Authz, Stat, AgentId) ->
    #config{
        id=AgentId,
        authn=Authn,
        authz=Authz,
        stat=Stat}.

make_sample_session(Mode) ->
    #session{
        id= <<"00000000-0000-0000-0000-000000000010">>,
        parent_id= <<"00000000-0000-0000-0000-000000000000">>,
        connection=#connection{mode=Mode, version=?VER_2},
        created_at=0}.

make_sample_broker_session() ->
    #session{
        id= <<"00000000-0000-0000-0000-000000000000">>,
        parent_id= <<"00000000-0000-0000-0000-000000000000">>,
        connection=#connection{mode=service, version=?VER_2},
        created_at=0}.

make_sample_tracking_id() ->
    <<"00000000-0000-0000-0000-000000000100"
      ".00000000-0000-0000-0000-000000000010"
      ".00000000-0000-0000-0000-000000000000">>.

make_sample_tracking_label() ->
    <<"00000000-0000-0000-0000-000000000010.00000000-0000-0000-0000-000000000000">>.

make_sample_broker_state(Config, Session, Time) ->
    #state{
        config=Config,
        session=Session,
        unique_id= <<"00000000-0000-0000-0000-000000000100">>,
        time=Time}.

make_sample_broker_config(BrokerAud, Trusted) ->
    BrokerId =
        #{label => <<"alpha">>,
          account_id =>
            #{label => <<"mqtt-gateway">>,
              audience => BrokerAud}},
    Config =
        #{BrokerAud =>
          #{type => trusted,
            trusted => gb_sets:from_list(Trusted)}},

    #{id => BrokerId,
      config => Config}.

make_sample_broker_id(Aud) ->
    #{label => <<"alpha">>,
      account_id =>
        #{label => <<"mqtt-gateway">>,
          audience => Aud}}.

make_sample_broker_id() ->
    make_sample_broker_id(<<"example.org">>).

make_sample_agent_id(AgentLabel, AccountLabel, Audience) ->
    #{label => AgentLabel,
      account_id =>
        #{label => AccountLabel,
          audience => Audience}}.

%% TODO: remove v1
v1_make_sample_client_id(AgentLabel, AccountLabel, Audience, Mode, Version) ->
    AgentId = <<AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>,
    ModeLabel =
        case Mode of
            default -> <<Version/binary, "/agents">>;
            service -> <<Version/binary, "/service-agents">>;
            observer -> <<Version/binary, "/observer-agents">>;
            bridge -> <<Version/binary, "/bridge-agents">>
        end,

    <<ModeLabel/binary, $/, AgentId/binary>>.

-spec make_sample_connection_properties(connection_mode()) -> map().
make_sample_connection_properties(Mode) ->
    UserProperties =
        [{<<"connection_version">>, ?VER_2},
         {<<"connection_mode">>, format_connection_mode(Mode)}],
    #{p_user_property => UserProperties}.

make_sample_message_bridgecompat(Mode, Time) ->
    make_sample_message_bridgecompat(Mode, Time, <<>>, #{}).

make_sample_message_bridgecompat(Mode, Time, Payload, Properties) ->
    case Mode of
        Mode when
            (Mode =:= default) or (Mode =:= service) or (Mode =:= observer) ->
            #message{
                payload = Payload,
                properties = add_local_timestamp(Mode, Time, Properties)};
        bridge ->
            #message
                {payload = Payload,
                properties = update_sample_message_properties(Properties)};
        _ ->
            error({bad_mode, Mode})
    end.

update_sample_message_properties(Properties) ->
    DefaultSampleUserProperties =
        #{<<"agent_id">> => <<"test-1.john-doe.example.org">>,
          %% TODO: remove v1
          <<"agent_label">> => <<"test-1">>,
          <<"account_label">> => <<"john-doe">>,
          <<"audience">> => <<"example.org">>},

    UserProperties0 = maps:from_list(maps:get(p_user_property, Properties, [])),
    UserProperties1 = maps:merge(DefaultSampleUserProperties, UserProperties0),
    Properties#{p_user_property => maps:to_list(UserProperties1)}.

add_local_timestamp(default, Time, Properties) ->
    L = maps:get(p_user_property, Properties, []),
    Properties#{p_user_property => [{<<"local_timestamp">>, integer_to_binary(Time)}|L]};
add_local_timestamp(_, _Time, Properties) ->
    Properties.

-endif.
