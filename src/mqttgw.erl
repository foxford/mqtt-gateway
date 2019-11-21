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
    handle_connect/4,
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
-define(VER, <<"v1">>).

%% Types
-type qos() :: 0..2.
-type topic() :: [binary()].
-type subscription() :: {topic(), qos()}.
-type connection() :: binary().

-type connection_mode() :: default | service | observer | bridge.

-record(client_id, {
    mode          :: connection_mode(),
    agent_label   :: binary(),
    account_label :: binary(),
    audience      :: binary()
}).
-type client_id() :: #client_id{}.

-record(session, {
    id         :: binary(),
    parent_id  :: binary(),
    mode       :: connection_mode(),
    version    :: binary(),
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

-spec handle_connect(connection(), binary(), boolean(), initial_state()) -> ok | {error, error()}.
handle_connect(Conn, Password, CleanSession, State) ->
    try validate_client_id(parse_client_id(Conn)) of
        ClientId ->
            handle_connect_constraints(ClientId, Password, CleanSession, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: an invalid client_id = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Conn, T, R]),
            {error, #{reason_code => client_identifier_not_valid}}
    end.

-spec handle_connect_constraints(client_id(), binary(), boolean(), initial_state())
    -> ok | {error, error()}.
handle_connect_constraints(ClientId, Password, CleanSession, State) ->
    try verify_connect_constraints(CleanSession, ClientId#client_id.mode) of
        _ ->
            handle_connect_authn_config(ClientId, Password, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: invalid constraints check, clean_session = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [CleanSession, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_connect_authn_config(client_id(), binary(), initial_state())
    -> ok | {error, error()}.
handle_connect_authn_config(ClientId, Password, State) ->
    case State#initial_state.config#config.authn of
        disabled ->
            DirtyAccountId =
                #{label => ClientId#client_id.account_label,
                  audience => ClientId#client_id.audience},
            handle_connect_authz_config(ClientId, DirtyAccountId, State);
        {enabled, Config} ->
            handle_connect_authn(ClientId, Password, Config, State)
    end.

-spec handle_connect_authn(client_id(), binary(), mqttgw_authn:config(), initial_state())
    -> ok | {error, error()}.
handle_connect_authn(ClientId, Password, Config, State) ->
    DirtyAccountId =
        #{label => ClientId#client_id.account_label,
          audience => ClientId#client_id.audience},
    try mqttgw_authn:authenticate(Password, Config) of
        AccountId when AccountId =:= DirtyAccountId ->
            handle_connect_authz_config(ClientId, AccountId, State);
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

-spec handle_connect_authz_config(client_id(), mqttgw_authn:account_id(), initial_state())
    -> ok | {error, error()}.
handle_connect_authz_config(ClientId, AccountId, State) ->
    #client_id{mode=Mode} = ClientId,

    case State#initial_state.config#config.authz of
        disabled ->
            handle_connect_success(ClientId, State);
        {enabled, Config} ->
            BrokerId = broker_client_id(State#initial_state.config#config.id),
            handle_connect_authz(Mode, ClientId, AccountId, BrokerId, Config, State)
    end.

-spec handle_connect_authz(
    connection_mode(), client_id(), mqttgw_authn:account_id(),
    client_id(), mqttgw_authz:config(), initial_state())
    -> ok | {error, error()}.
handle_connect_authz(default, ClientId, _AccountId, _BrokerId, _Config, State) ->
    handle_connect_success(ClientId, State);
handle_connect_authz(_Mode, ClientId, AccountId, BrokerId, Config, State) ->
    #client_id{mode=Mode} = ClientId,

    try mqttgw_authz:authorize(BrokerId#client_id.audience, AccountId, Config) of
        _ ->
            handle_connect_success(ClientId, State)
    catch
        T:R ->
            error_logger:warning_msg(
                "Error on connect: connecting in mode = '~s' isn't allowed "
                "for the agent = ~p, "
                "exception_type = ~p, exception_reason = ~p",
                [Mode, agent_id(ClientId), T, R]),
            {error, #{reason_code => not_authorized}}
    end.

-spec handle_connect_success(client_id(), initial_state()) -> ok | {error, error()}.
handle_connect_success(ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    %% Get the broker session id
    Config = mqttgw_state:get(config),
    BrokerId = broker_client_id(Config#config.id),
    #session{id=ParentSessionId} = mqttgw_state:get(BrokerId),

    %% Create an agent session
    Session =
        #session{
            id=make_uuid(),
            parent_id=ParentSessionId,
            mode=Mode,
            version=?VER,
            created_at=State#initial_state.time},
    mqttgw_state:put(ClientId, Session),

    handle_connect_success_stat_config(
        ClientId,
        broker_state(
            State#initial_state.config,
            Session,
            State#initial_state.time)),

    error_logger:info_msg(
        "Agent = '~s' connected: mode = '~s'",
        [agent_id(ClientId), Mode]),
    ok.

-spec handle_connect_success_stat_config(client_id(), state()) -> ok.
handle_connect_success_stat_config(ClientId, State) ->
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
                    id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => agent_id(ClientId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                BrokerId,
                ClientId,
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

-spec handle_disconnect(connection(), client_id(), state()) -> ok.
handle_disconnect(Conn, ClientId, State) ->
    handle_disconnect_authz_config(Conn, ClientId, State).

-spec handle_disconnect_authz_config(connection(), client_id(), state()) -> ok.
handle_disconnect_authz_config(Conn, ClientId, State) ->
    case State#state.config#config.authz of
        disabled ->
            handle_disconnect_stat_config(ClientId, State);
        {enabled, _Config} ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{id=SessionId, parent_id=ParentSessionId},
                config=#config{id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            delete_client_dynsubs(Conn, BrokerId, UniqueId, SessionPairId, Time),
            handle_disconnect_stat_config(ClientId, State)
    end.

-spec handle_disconnect_stat_config(client_id(), state()) -> ok | {error, error()}.
handle_disconnect_stat_config(ClientId, State) ->
    case State#state.config#config.stat of
        disabled ->
            handle_disconnect_success(ClientId);
        enabled ->
            #state{
                time=Time,
                unique_id=UniqueId,
                session=#session{
                    id=SessionId,
                    parent_id=ParentSessionId,
                    created_at=Ts},
                config=#config{
                    id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => agent_id(ClientId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
                BrokerId,
                ClientId,
                UniqueId,
                SessionPairId,
                Time),
            handle_disconnect_success(ClientId)
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

-spec handle_publish_mqtt3_constraints(
    topic(), binary(), qos(), boolean(), client_id(), state())
    -> {ok, list()} | {error, error()}.
handle_publish_mqtt3_constraints(Topic, InputPayload, QoS, IsRetain, ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt3(Topic, InputPayload, ClientId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt3(topic(), binary(), client_id(), state())
    -> {ok, list()} | {error, error()}.
handle_publish_mqtt3(Topic, InputPayload, ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    BrokerId = broker_client_id(State#state.config#config.id),
    try handle_message_properties(
        handle_mqtt3_envelope_properties(validate_envelope(parse_envelope(InputPayload))),
        ClientId,
        BrokerId,
        State) of
        Message ->
            case handle_publish_authz(Topic, Message, ClientId, State) of
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

-spec handle_publish_mqtt5_constraints(
    topic(), binary(), map(), qos(), boolean(), client_id(), state())
    -> {ok, map()} | {error, error()}.
handle_publish_mqtt5_constraints(
    Topic, InputPayload, InputProperties, QoS, IsRetain, ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_constraints(QoS, IsRetain, Mode) of
        _ ->
            handle_publish_mqtt5(Topic, InputPayload, InputProperties, ClientId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: invalid constraints check, qos = ~p, retain = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [QoS, IsRetain, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec handle_publish_mqtt5(topic(), binary(), map(), client_id(), state())
    -> {ok, map()} | {error, error()}.
handle_publish_mqtt5(Topic, InputPayload, InputProperties, ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    BrokerId = broker_client_id(State#state.config#config.id),
    InputMessage = #message{payload = InputPayload, properties = InputProperties},
    try handle_message_properties(InputMessage, ClientId, BrokerId, State) of
        Message ->
            case handle_publish_authz(Topic, Message, ClientId, State) of
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

-spec handle_publish_authz(topic(), message(), client_id(), state())
    -> ok | {error, error()}.
handle_publish_authz(Topic, Message, ClientId, State) ->
    handle_publish_authz_config(Topic, Message, ClientId, State).

-spec handle_publish_authz_config(topic(), message(), client_id(), state())
    -> ok | {error, error()}.
handle_publish_authz_config(Topic, Message, ClientId, State) ->
    case State#state.config#config.authz of
        disabled ->
            ok;
        {enabled, _Config} ->
            BrokerId = broker_client_id(State#state.config#config.id),
            handle_publish_authz_topic(Topic, Message, BrokerId, ClientId, State)
    end.

-spec handle_publish_authz_topic(topic(), message(), client_id(), client_id(), state())
    -> ok | {error, error()}.
handle_publish_authz_topic(Topic, Message, BrokerId, ClientId, State) ->
    #client_id{mode=Mode} = ClientId,

    try verify_publish_topic(Topic, account_id(ClientId), agent_id(ClientId), Mode) of
        _ ->
            handle_publish_authz_broker_request(
                Topic, Message, account_id(BrokerId), agent_id(BrokerId), BrokerId, ClientId, State)
    catch
        T:R ->
            error_logger:error_msg(
                "Error on publish: publishing to the topic = ~p isn't allowed "
                "for the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Topic, agent_id(ClientId), Mode, T, R]),
            {error, #{reason_code => not_authorized}}
    end.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

-spec handle_publish_authz_broker_request(
    topic(), message(), binary(), binary(), client_id(), client_id(), state())
    -> ok | {error, error()}.
% handle_publish_authz_broker_request(
%     [<<"agents">>, _, <<"api">>, Version, <<"out">>, BrokerAccoundId],
%     Message, BrokerAccoundId, _BrokerAgentId, BrokerId, ClientId, State) ->
%         handle_publish_authz_broker_request_payload(Version, Message, BrokerId, ClientId, State);
handle_publish_authz_broker_request(
    _Topic, _Message, _BrokerAccoundId, _BrokerAgentId, _BrokerId, _ClientId, _State) ->
        ok.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

% -spec handle_publish_authz_broker_request_payload(
%    binary(), message(), client_id(), client_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_request_payload(
%     Version, #message{payload = Payload, properties = Properties}, BrokerId, ClientId, State) ->
%     #client_id{mode=Mode} = ClientId,

%     try {Mode, jsx:decode(Payload, [return_maps]), parse_broker_request_properties(Properties)} of
%         {service,
%          #{<<"object">> := Object,
%            <<"subject">> := Subject},
%          #{type := <<"request">>,
%            method := <<"subscription.create">>,
%            correlation_data := CorrData,
%            response_topic := RespTopic}} ->
%                handle_publish_authz_broker_dynsub_create_request(
%                    Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId, State);
%         {service,
%          #{<<"object">> := Object,
%            <<"subject">> := Subject},
%          #{type := <<"request">>,
%            method := <<"subscription.delete">>,
%            correlation_data := CorrData,
%            response_topic := RespTopic}} ->
%                handle_publish_authz_broker_dynsub_delete_request(
%                    Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId, State);
%         _ ->
%             error_logger:error_msg(
%                 "Error on publish: unsupported broker request = ~p with properties = ~p "
%                 "from the agent = '~s' using mode = '~s', ",
%                 [Payload, Properties, agent_id(ClientId), Mode]),
%             {error, #{reason_code => impl_specific_error}}
%     catch
%         T:R ->
%             error_logger:error_msg(
%                 "Error on publish: an invalid broker request = ~p with properties = ~p "
%                 "from the agent = '~s' using mode = '~s', "
%                 "exception_type = ~p, exception_reason = ~p",
%                 [Payload, Properties, agent_id(ClientId), Mode, T, R]),
%             {error, #{reason_code => impl_specific_error}}
%     end.

% -spec handle_publish_authz_broker_dynsub_create_request(
%     binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
%     binary(), binary(), client_id(), client_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_dynsub_create_request(
%     Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId, State) ->
%     #client_id{
%         account_label=AccountLabel,
%         audience=Audience} = ClientId,
%     #state{
%         time=Time,
%         unique_id=UniqueId,
%         session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
%     SessionPairId = format_session_id(SessionId, ParentSessionId),

%     %% Subscribe the agent to the app's topic and send a success response
%     App = mqttgw_authn:format_account_id(#{label => AccountLabel, audience => Audience}),
%     Data = #{app => App, object => Object, version => Version},
%     create_dynsub(Subject, Data),

%     %% Send an unicast response to the 3rd-party agent
%     send_dynsub_response(
%         App, CorrData, RespTopic, BrokerId, ClientId,
%         UniqueId, SessionPairId, Time),

%     %% Send a multicast event to the application
%     send_dynsub_event(
%         <<"subscription.create">>, Subject, Data, BrokerId,
%         UniqueId, SessionPairId, Time),
%     ok.

% -spec handle_publish_authz_broker_dynsub_delete_request(
%     binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
%     binary(), binary(), client_id(), client_id(), state())
%     -> ok | {error, error()}.
% handle_publish_authz_broker_dynsub_delete_request(
%     Version, Object, Subject, CorrData, RespTopic, BrokerId, ClientId, State) ->
%     #client_id{
%         account_label=AccountLabel,
%         audience=Audience} = ClientId,
%     #state{
%         time=Time,
%         unique_id=UniqueId,
%         session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
%     SessionPairId = format_session_id(SessionId, ParentSessionId),

%     %% Unsubscribe the agent from the app's topic and send a success response
%     App = mqttgw_authn:format_account_id(#{label => AccountLabel, audience => Audience}),
%     Data = #{app => App, object => Object, version => Version},
%     delete_dynsub(Subject, Data),

%     %% Send an unicast response to the 3rd-party agent
%     send_dynsub_response(
%         App, CorrData, RespTopic, BrokerId, ClientId,
%         UniqueId, SessionPairId, Time),

%     %% Send a multicast event to the application
%     send_dynsub_event(
%         <<"subscription.delete">>, Subject, Data, BrokerId,
%         UniqueId, SessionPairId, Time),
%     ok.

-spec handle_message_properties(message(), client_id(), client_id(), state())
    -> message().
handle_message_properties(Message, ClientId, BrokerId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = format_session_id(SessionId, ParentSessionId),

    UpdatedProperties =
        validate_message_properties(
            update_message_properties(
                Message#message.properties,
                ClientId,
                BrokerId,
                UniqueId,
                SessionPairId,
                Time),
            ClientId),

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
                    verify_response_topic(binary:split(RT, <<$/>>, [global]), agent_id(ClientId))
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
    map(), client_id(), client_id(), binary(), binary(), non_neg_integer())
    -> map().
update_message_properties(Properties, ClientId, BrokerId, UniqueId, SessionPairId, Time) ->
    #client_id{
        agent_label=BrokerAgentLabel,
        account_label=BrokerAccountLabel,
        audience=BrokerAudience} = BrokerId,
    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = ClientId,

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
                validate_authn_properties(UserProperties1);
            _ ->
                UserProperties1#{
                    <<"agent_label">> => AgentLabel,
                    <<"account_label">> => AccountLabel,
                    <<"audience">> => Audience}
        end,

    %% Additional connection properties
    UserProperties3 =
        UserProperties2#{
            <<"connection_version">> => ?VER,
            <<"connection_mode">> => format_connection_mode(Mode)},

    %% Additional broker properties
    UserProperties4 =
        UserProperties3#{
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
-spec handle_deliver_authz_config(topic(), message(), client_id(), state()) -> message().
handle_deliver_authz_config(Topic, Message, RecvId, State) ->
    case State#state.config#config.authz of
        disabled ->
            Message;
        {enabled, _Config} ->
            BrokerId = broker_client_id(State#state.config#config.id),
            handle_deliver_authz_broker_request(
                Topic, Message, BrokerId, RecvId, State)
    end.

-spec handle_deliver_authz_broker_request(
    topic(), message(), client_id(), client_id(), state())
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
    binary(), binary(), message(), client_id(), client_id(), state())
    -> message().
handle_deliver_authz_broker_request_payload(
    Version, App, #message{payload = Payload, properties = Properties} =Message,
    BrokerId, RecvId, State) ->
    #client_id{mode=Mode} = RecvId,

    try {jsx:decode(Payload, [return_maps]), parse_deliver_broker_request_properties(Properties)} of
        {#{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.create">>,
           connection_mode := <<"service-agents">>,
           correlation_data := CorrData,
           sent_by := ClientId}} ->
                case catch parse_client_id(Subject) of
                    RecvId ->
                        handle_deliver_authz_broker_dynsub_create_request(
                            Version, App, Object, Subject, CorrData, BrokerId, ClientId, State);
                    _ ->
                        %% NOTE: don't do anything if a delivery callback was called
                        %% for a different than the subject agent
                        Message
                end;
        {#{<<"object">> := Object,
           <<"subject">> := Subject},
         #{type := <<"request">>,
           method := <<"subscription.delete">>,
           connection_mode := <<"service-agents">>,
           correlation_data := CorrData,
           sent_by := ClientId}} ->
                case catch parse_client_id(Subject) of
                    RecvId ->
                        handle_deliver_authz_broker_dynsub_delete_request(
                            Version, App, Object, Subject, CorrData, BrokerId, ClientId, State);
                    _ ->
                        %% NOTE: don't do anything if a delivery callback was called
                        %% for a different than the subject agent
                        Message
                end;
        _ ->
            error_logger:error_msg(
                "Error on deliver: unsupported broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', ",
                [Payload, Properties, agent_id(RecvId), Mode]),
            create_dynsub_error_response()
    catch
        T:R ->
            error_logger:error_msg(
                "Error on deliver: an invalid broker request = ~p with properties = ~p "
                "from the agent = '~s' using mode = '~s', "
                "exception_type = ~p, exception_reason = ~p",
                [Payload, Properties, agent_id(RecvId), Mode, T, R]),
            create_dynsub_error_response()
    end.

-spec handle_deliver_authz_broker_dynsub_create_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), client_id(), client_id(), state())
    -> message().
handle_deliver_authz_broker_dynsub_create_request(
    Version, App, Object, Subject, CorrData, BrokerId, ClientId, State) ->
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
        <<"subscription.create">>, Subject, Data, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    create_dynsub_response(
        CorrData, BrokerId, ClientId,
        UniqueId, SessionPairId, Time).

-spec handle_deliver_authz_broker_dynsub_delete_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), client_id(), client_id(), state())
    -> message().
handle_deliver_authz_broker_dynsub_delete_request(
    Version, App, Object, Subject, CorrData, BrokerId, ClientId, State) ->
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
        <<"subscription.delete">>, Subject, Data, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    create_dynsub_response(
        CorrData, BrokerId, ClientId,
        UniqueId, SessionPairId, Time).

-spec create_dynsub_response(
    binary(), client_id(), client_id(), binary(), binary(), non_neg_integer())
    -> message().
create_dynsub_response(CorrData, BrokerId, SenderId, UniqueId, SessionPairId, Time) ->
    #message{
        payload = jsx:encode(#{}),
        properties =
            validate_message_properties(
                update_message_properties(
                    #{p_correlation_data => CorrData,
                        p_user_property =>
                        [ {<<"type">>, <<"response">>},
                          {<<"status">>, <<"200">>} ]},
                    SenderId,
                    BrokerId,
                    UniqueId,
                    SessionPairId,
                    Time
                ),
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
    {_, AgentLabel} = lists:keyfind(<<"agent_label">>, 1, UserProperties),
    {_, AccountLabel} = lists:keyfind(<<"account_label">>, 1, UserProperties),
    {_, Audience} = lists:keyfind(<<"audience">>, 1, UserProperties),
    #{type => Type,
      method => Method,
      connection_mode => ConnMode,
      correlation_data => CorrData,
      response_topic => RespTopic,
      sent_by => broker_client_id(
          parse_connection_nmode({ConnVer, ConnMode}),
          #{label => AgentLabel, account_id => #{label => AccountLabel, audience => Audience}})}.
%% <<<<< END

-spec handle_deliver_mqtt3(topic(), binary(), client_id(), state())
    -> ok | {ok, list()} | {error, error()}.
handle_deliver_mqtt3(Topic, InputPayload, RecvId, State) ->
    #client_id{mode=Mode} = RecvId,

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
                [InputPayload, agent_id(RecvId), Mode, T, R]),
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
    topic(), binary(), map(), client_id(), state())
    -> ok | {ok, map()} | {error, error()}.
handle_deliver_mqtt5(Topic, InputPayload, _InputProperties, RecvId, State) ->
    #client_id{mode=Mode} = RecvId,

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
                [InputPayload, agent_id(RecvId), Mode, T, R]),
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

-spec handle_subscribe_authz([subscription()], client_id(), state()) ->ok | {error, error()}.
handle_subscribe_authz(Subscriptions, ClientId, State) ->
    handle_subscribe_authz_config(Subscriptions, ClientId, State).

-spec handle_subscribe_authz_config([subscription()], client_id(), state()) ->ok | {error, error()}.
handle_subscribe_authz_config(Subscriptions, ClientId, State) ->
    case State#state.config#config.authz of
        disabled ->
            handle_subscribe_success(Subscriptions, ClientId);
        {enabled, _Config} ->
            handle_subscribe_authz_topic(Subscriptions, ClientId)
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
                    id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.enter">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
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
                config=#config{id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            erase_dynsubs(BrokerId, UniqueId, SessionPairId, Time),
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
                    id=IdM}} = State,
            BrokerId = broker_client_id(IdM),
            SessionPairId = format_session_id(SessionId, ParentSessionId),

            send_audience_event(
                #{id => agent_id(BrokerId)},
                [ {<<"type">>, <<"event">>},
                  {<<"label">>, <<"agent.leave">>},
                  {<<"timestamp">>, integer_to_binary(Ts)} ],
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
    Mode = service,
    Time = os:system_time(millisecond),
    Session =
        #session{
            id=make_uuid(),
            parent_id=make_uuid(),
            mode=Mode,
            version=?VER,
            created_at=Time},
    mqttgw_state:put(broker_client_id(BrokerId), Session),

    handle_broker_start(broker_state(Config, Session, Time)),
    ok.

-spec stop() -> ok.
stop() ->
    Config = mqttgw_state:get(config),
    Time = os:system_time(millisecond),
    ClientId = broker_client_id(Config#config.id),
    handle_broker_stop(broker_state(Config, mqttgw_state:get(ClientId), Time)).

auth_on_register(
    _Peer, {_MountPoint, Conn} = _SubscriberId, _Username,
    Password, CleanSession) ->
    State = broker_initial_state(mqttgw_state:get(config), os:system_time(millisecond)),
    case handle_connect(Conn, Password, CleanSession, State) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_register_m5(
    _Peer, {_MountPoint, Conn} = _SubscriberId, _Username,
    Password, CleanSession, _Properties) ->
    State = broker_initial_state(mqttgw_state:get(config), os:system_time(millisecond)),
    handle_connect(Conn, Password, CleanSession, State).

auth_on_publish(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_publish_mqtt3_constraints(
        Topic, Payload, QoS, IsRetain, ClientId, State).

auth_on_publish_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    QoS, Topic, Payload, IsRetain, Properties) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_publish_mqtt5_constraints(
        Topic, Payload, Properties, QoS, IsRetain, ClientId, State).

on_deliver(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Topic, Payload) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_deliver_mqtt3(Topic, Payload, ClientId, State).

on_deliver_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Topic, Payload, Properties) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_deliver_mqtt5(Topic, Payload, Properties, ClientId, State).

auth_on_subscribe(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    case handle_subscribe_authz(Subscriptions, ClientId, State) of
        ok ->
            ok;
        {error, #{reason_code := Reason}} ->
            {error, Reason}
    end.

auth_on_subscribe_m5(
    _Username, {_MountPoint, Conn} = _SubscriberId,
    Subscriptions, _Properties) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_subscribe_authz(Subscriptions, ClientId, State).

on_client_offline({_MountPoint, Conn} = _SubscriberId) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_disconnect(Conn, ClientId, State).

on_client_gone({_MountPoint, Conn} = _SubscriberId) ->
    ClientId = parse_client_id(Conn),
    State = broker_state(
        mqttgw_state:get(config),
        mqttgw_state:get(ClientId),
        os:system_time(millisecond)),
    handle_disconnect(Conn, ClientId, State).

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
    broker_client_id(service, AgentId).

-spec broker_client_id(connection_mode(), mqttgw_id:agent_id()) -> client_id().
broker_client_id(Mode, AgentId) ->
    #client_id
        {mode = Mode,
         agent_label = mqttgw_id:label(AgentId),
         account_label = mqttgw_id:account_label(AgentId),
         audience = mqttgw_id:audience(AgentId)}.

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

-spec format_connection_mode(connection_mode()) -> binary().
format_connection_mode(default)  -> <<"agents">>;
format_connection_mode(service)  -> <<"service-agents">>;
format_connection_mode(observer) -> <<"observer-agents">>;
format_connection_mode(bridge)   -> <<"bridge-agents">>.

-spec parse_connection_nmode({binary(), binary()}) -> connection_mode().
parse_connection_nmode({?VER, <<"agents">>}) -> default;
parse_connection_nmode({?VER, <<"service-agents">>}) -> service;
parse_connection_nmode({?VER, <<"observer-agents">>}) -> observer;
parse_connection_nmode({?VER, <<"bridge-agents">>}) -> bridge;
parse_connection_nmode(VerMode) -> error({bad_versionmode, VerMode}).

-spec parse_client_id(binary()) -> client_id().
parse_client_id(<<"v1/agents/", R/bits>>) ->
    parse_v1_agent_label(R, default, <<>>);
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
    mqttgw_dynsub:subject(), client_id(), binary(), binary(), non_neg_integer())
    -> ok.
delete_client_dynsubs(Subject, BrokerId, UniqueId, SessionPairId, Time) ->
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
        <<"subscription.delete">>, Subject, Data, BrokerId,
        UniqueId, SessionPairId, Time)
     || Data <- DynSubL],

    %% Remove subscriptions
    [delete_dynsub(Subject, Data) || Data  <- DynSubL],

    ok.

-spec erase_dynsubs(client_id(), binary(), binary(), non_neg_integer()) -> ok.
erase_dynsubs(BrokerId, UniqueId, SessionPairId, Time) ->
    [delete_client_dynsubs(Subject, BrokerId, UniqueId, SessionPairId, Time)
     || Subject <- mqttgw_broker:list_connections()],
    ok.

%% TODO: remove the local state
%% TODO: uncomment the lines bellow

% -spec send_dynsub_response(
%     binary(), binary(), binary(), client_id(), client_id(), binary(), binary(), non_neg_integer())
%     -> ok.
% send_dynsub_response(
%     App, CorrData, RespTopic, BrokerId,
%     UniqueId, SessionPairId, SenderId, Time) ->
%     #client_id{mode=Mode} = SenderId,

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
%                             SenderId,
%                             BrokerId,
%                             UniqueId,
%                             SessionPairId,
%                             Time
%                         ),
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
%                 [RespTopic, agent_id(SenderId), Mode, agent_id(BrokerId), T, R]),
%             {error, #{reason_code => impl_specific_error}}
%     end.

-spec send_dynsub_event(
    binary(), mqttgw_dynsub:subject(), mqttgw_dynsub:data(),
    client_id(), binary(), binary(), non_neg_integer())
    -> ok.
send_dynsub_event(Label, Subject, Data, SenderId, UniqueId, SessionPairId, Time) ->
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
                            SenderId,
                            SenderId,
                            UniqueId,
                            SessionPairId,
                            Time
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

-spec send_audience_event(
    map(), list(), client_id(), client_id(), binary(), binary(), non_neg_integer())
    -> ok.
send_audience_event(Payload, UserProperties, SenderId, ClientId, UniqueId, SessionPairId, Time) ->
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
                            #{p_user_property => UserProperties},
                            SenderId,
                            SenderId,
                            UniqueId,
                            SessionPairId,
                            Time
                        ),
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
                [UserProperties, Topic, agent_id(SenderId), T, R]),
            {error, #{reason_code => impl_specific_error}}
    end.

-spec audience_event_topic(client_id(), client_id()) -> topic().
audience_event_topic(ClientId, BrokerId) ->
    [<<"apps">>, account_id(BrokerId),
     <<"api">>, ?VER, <<"audiences">>, ClientId#client_id.audience, <<"events">>].

-spec dynsub_event_topic(binary(), client_id()) -> topic().
dynsub_event_topic(App, BrokerId) ->
    [<<"agents">>, agent_id(BrokerId),
     <<"api">>, ?VER, <<"out">>, App].

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

version_mode_t() ->
    ?LET(
        Index,
        choose(1, 4),
        lists:nth(Index,
            [{?VER, <<"agents">>},
             {?VER, <<"bridge-agents">>},
             {?VER, <<"observer-agents">>},
             {?VER, <<"service-agents">>}])).

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
        {SubscriberId, Password},
        {subscriber_id_t(), binary_utf8_t()},
        begin
            CleanSession = minimal_constraint(clean_session),

            Time = 0,
            IdM = make_sample_broker_idm(),
            BrokerId = broker_client_id(IdM),
            Conn = element(2, SubscriberId),
            Config = make_sample_config(disabled, disabled, disabled),
            State = broker_initial_state(Config, Time),

            %% NOTE: we use it to read the broker config and store agent's initial state
            mqttgw_state:new(),
            mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, IdM)),
            mqttgw_state:put(BrokerId, make_sample_broker_session()),

            ok = handle_connect(Conn, Password, CleanSession, State),
            true
        end).

prop_onconnect_invalid_credentials() ->
    ?FORALL(
        {Conn, Password},
        {binary(32), binary_utf8_t()},
        begin
            CleanSession = minimal_constraint(clean_session),

            Time = 0,
            Config = make_sample_config(disabled, disabled, disabled),
            State = make_sample_broker_state(Config, make_sample_broker_session(), Time),

            {error, #{reason_code := client_identifier_not_valid}} =
                handle_connect(Conn, Password, CleanSession, State),
            true
        end).

authz_onconnect_test_() ->
    CleanSession = minimal_constraint(clean_session),
    Time = 0,

    AgentLabel = <<"foo">>,
    AccountLabel = <<"bar">>,
    SvcAud = IdMAud = <<"svc.example.org">>,
    SvcAccountId = #{label => AccountLabel, audience => SvcAud},
    UsrAud = <<"usr.example.net">>,

    #{password := SvcPassword,
      config := SvcAuthnConfig} =
        make_sample_password(<<"bar">>, SvcAud, <<"svc.example.org">>),
    #{password := UsrPassword,
      config := UsrAuthnConfig} =
        make_sample_password(<<"bar">>, UsrAud, <<"iam.svc.example.net">>),
    #{me := IdM,
      config := AuthzConfig} = make_sample_broker_config(IdMAud, [SvcAccountId]),
    BrokerId = broker_client_id(IdM),

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
    mqttgw_state:put(config, make_sample_config(disabled, disabled, disabled, IdM)),
    mqttgw_state:put(BrokerId, make_sample_broker_session()),

    %% 1 - authn: enabled, authz: disabled
    %% Anyone can connect in any mode when authz is dissabled
    State1 = fun(Mode) ->
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                disabled,
                disabled,
                IdM),
            Time)
        end,
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER),
            Result = handle_connect(ClientId, Password, CleanSession, State1(Mode)),
            {Desc, ?_assertEqual(ok, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, _Expect} <- Test],

    %% 2 - authn: enabled, authz: enabled
    %% User accounts can connect only in 'default' mode
    %% Service accounts can connect in any mode
    State2 = fun(Mode) ->
        broker_initial_state(
            make_sample_config(
                {enabled, maps:merge(UsrAuthnConfig, SvcAuthnConfig)},
                {enabled, AuthzConfig},
                disabled,
                IdM),
            Time)
        end,
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER),
            Result = handle_connect(ClientId, Password, CleanSession, State2(Mode)),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test],

    %% 3 - authn: disabled, authz: enabled
    State3 = fun(Mode) ->
        broker_initial_state(
            make_sample_config(
                disabled,
                {enabled, AuthzConfig},
                disabled,
                IdM),
            Time)
        end,
    [begin
        [begin
            ClientId =
                make_sample_connection_client_id(
                    AgentLabel, AccountLabel, Aud, Mode, ?VER),
            Result = handle_connect(ClientId, Password, CleanSession, State3(Mode)),
            {Desc, ?_assertEqual(Expect, Result)}
        end || Mode <- Modes]
    end || {Desc, Modes, Aud, Password, Expect} <- Test].

message_connect_constraints_test_() ->
    AnyMode = [default, service, observer, bridge],
    TrustedMode = [service, observer, bridge],
    NonTrustedMode = AnyMode -- TrustedMode,
    AnyCleanSession = [false, true],
    MinCleanSession = [true],

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
        {Username, SubscriberId, Topic, Payload},
        {binary_utf8_t(), subscriber_id_t(), publish_topic_t(), binary_utf8_t()},
        begin
            QoS = minimal_constraint(qos),
            IsRetain = minimal_constraint(retain),
            IdM = make_sample_broker_idm(),
            Time = 0,
            TimeB = TimeDiffB = integer_to_binary(Time),

            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = ClientId = parse_client_id(element(2, SubscriberId)),
            State = make_sample_broker_state(
                make_sample_config(disabled, disabled, disabled, IdM),
                make_sample_session(Mode),
                Time),
            ExpectedBrokerL =
                [ {<<"broker_agent_label">>, mqttgw_id:label(IdM)},
                  {<<"broker_account_label">>, mqttgw_id:account_label(IdM)},
                  {<<"broker_audience">>, mqttgw_id:audience(IdM)},
                  {<<"broker_processing_timestamp">>, TimeB},
                  {<<"broker_initial_processing_timestamp">>, TimeB} ],
            ExpectedConnectionL =
                [ {<<"connection_version">>, ?VER},
                  {<<"connection_mode">>, format_connection_mode(Mode)} ],
            ExpectedAuthnUserL =
                [ {<<"agent_label">>, AgentLabel},
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
                            add_local_timestamp(Mode, Time, #{p_user_property => [?TYPE_TEST_PROP]});
                        bridge ->
                            ExpectedAuthnProperties
                    end,

                {ok, Modifiers} =
                    handle_publish_mqtt5_constraints(
                        Topic, Payload, InputProperties, QoS, IsRetain,
                        ClientId, State),

                %% TODO: don't modify message payload on publish (only properties)
                %% InputPayload = maps:get(payload, Modifiers),
                %% OutputUserProperties = maps:get(user_property, Modifiers),
                %% lists:usort(OutputUserProperties) == lists:usort(ExpectedUserL)
                ExpectedCompatMessage3 =
                    envelope(#message{payload = Payload, properties = ExpectedProperties(Mode)}),
                ExpectedCompatMessage3 = maps:get(payload, Modifiers),
                [] = maps:get(p_user_property, maps:get(properties, Modifiers))
            end,

            %% MQTT 3
            begin
                InputMessage3 =
                    case Mode of
                        M3 when (M3 =:= default) or (M3 =:= service) or (M3 =:= observer) ->
                            envelope(#message{
                                payload=Payload,
                                properties=add_local_timestamp(Mode, Time, #{p_user_property => [?TYPE_TEST_PROP]})});
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
                        ClientId, State),
                {_, ExpectedMessage3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

bridge_missing_properties_onpublish_test_() ->
    QoS = minimal_constraint(qos),
    IsRetain = minimal_constraint(retain),
    #client_id{mode=Mode} = ClientId =
        make_sample_client_id(<<"foo">>, <<"bar">>, <<"svc.example.org">>, bridge),
    IdM = make_sample_broker_idm(),
    Time = 0,
    State = make_sample_broker_state(
        make_sample_config(disabled, disabled, disabled, IdM),
        make_sample_session(Mode),
        Time),

    Test =
        [{"missing properties", #{}},
         {"missing agent_label", #{<<"account_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing account_label", #{<<"agent_label">> => <<>>, <<"audience">> => <<>>}},
         {"missing audience", #{<<"agent_label">> => <<>>, <<"account_label">> => <<>>}}],

    [begin
        Message = jsx:encode(#{payload => <<>>, properties => Properties}),
        Expect = {error, #{reason_code => impl_specific_error}},

        [{Desc, ?_assertEqual(Expect, handle_publish_mqtt5([], Message, #{}, ClientId, State))},
         {Desc, ?_assertEqual(Expect, handle_publish_mqtt3([], Message, ClientId, State))}]
     end || {Desc, Properties} <- Test].

authz_onpublish_test_() ->
    Time = 0,
    IdM = make_sample_broker_idm(<<"aud">>),
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, {enabled, ignore}, disabled, IdM),
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
    Broadcast = fun(ClientId) ->
        [<<"apps">>, account_id(ClientId), <<"api">>, ?VER, <<>>]
    end,
    Multicast = fun(ClientId) ->
        [<<"agents">>, agent_id(ClientId), <<"api">>, ?VER, <<"out">>, <<>>]
    end,
    Unicast = fun(ClientId) ->
        [<<"agents">>, <<>>, <<"api">>, ?VER, <<"in">>, account_id(ClientId)]
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
            ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode),
            Result =
                case handle_publish_authz(TopicFn(ClientId), Message, ClientId, State(Mode)) of
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
    IdM = make_sample_broker_idm(),
    BrokerId = broker_client_id(IdM),
    ClientId = fun(Mode) ->
        make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode)
    end,
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, disabled, disabled, IdM),
            make_sample_session(Mode),
            Time)
    end,

    ResponseTopic = fun() ->
        <<"agents/", (agent_id(ClientId(default)))/binary, "/api/v1/in/baz.aud.example.org">>
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
                try handle_message_properties(Message, ClientId(Mode), BrokerId, State(Mode)) of
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
    IdM = make_sample_broker_idm(),
    BrokerId = broker_client_id(IdM),
    ClientId = fun(Mode) ->
        make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode)
    end,
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, disabled, disabled, IdM),
            make_sample_session(Mode),
            Time1)
    end,
    AnyMode = [default, service, observer, bridge],
    TrustedMode = [service, observer, bridge],
    NonTrustedMode = AnyMode -- TrustedMode,

    Test = [
        { "unset: broker_initial_processing_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP]},
          [{<<"broker_processing_timestamp">>, Time1B},
           {<<"broker_initial_processing_timestamp">>, Time1B}],
          ok },
        { "set: broker_initial_processing_timestamp",
          AnyMode,
          #{p_user_property => [?TYPE_TEST_PROP, {<<"broker_initial_processing_timestamp">>, Time0B}]},
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
                try handle_message_properties(Message, ClientId(Mode), BrokerId, State(Mode)) of
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
        {Username, SubscriberId, Topic, Payload},
        {binary_utf8_t(), subscriber_id_t(),
         publish_topic_t(), binary_utf8_t()},
        begin
            IdM = make_sample_broker_idm(),
            Time = 0,
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = ClientId = parse_client_id(element(2, SubscriberId)),
            ExpectedAuthnUserL =
                #{<<"agent_label">> => AgentLabel,
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
                make_sample_config(disabled, disabled, disabled, IdM),
                make_sample_session(Mode),
                Time),

            %% MQTT 5
            begin
                {ok, Modifiers} =
                    handle_deliver_mqtt5(Topic, InputPayload, #{}, ClientId, State),
                Payload = maps:get(payload, Modifiers)
            end,

            %% MQTT 3
            begin
                ExpectedPayload3 =
                    jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
                {ok, Modifiers3} =
                    handle_deliver_mqtt3(Topic, InputPayload, ClientId, State),
                {_, ExpectedPayload3} = lists:keyfind(payload, 1, Modifiers3)
            end,

            true
        end).

prop_onsubscribe() ->
    ?FORALL(
        {Username, SubscriberId, Subscription},
        {binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        begin
            Time = 0,
            IdM = make_sample_broker_idm(),
            #client_id{mode=Mode} = ClientId = parse_client_id(element(2, SubscriberId)),
            State = make_sample_broker_state(
                make_sample_config(disabled, disabled, disabled, IdM),
                make_sample_session(Mode),
                Time),

            ok =:= handle_subscribe_authz(Subscription, ClientId, State)
        end).

authz_onsubscribe_test_() ->
    Time = 0,
    IdM = make_sample_broker_idm(),

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
        [<<"apps">>, <<>>, <<"api">>, ?VER, <<>>]
    end,
    Multicast = fun(ClientId) ->
        [<<"agents">>, <<$+>>, <<"api">>, ?VER, <<"out">>, account_id(ClientId)]
    end,
    Unicast = fun(ClientId) ->
        [<<"agents">>, agent_id(ClientId), <<"api">>, ?VER, <<"in">>, <<$+>>]
    end,
    State = fun(Mode) ->
        make_sample_broker_state(
            make_sample_config(disabled, {enabled, ignore}, disabled, IdM),
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
            ClientId = make_sample_client_id(<<"foo">>, <<"bar">>, <<"aud.example.org">>, Mode),
            SubscriptionStd = [{TopicFn(ClientId), 0}],
            SubscriptionShared = [{[<<"$share">>, <<"g">> | TopicFn(ClientId)], 0}],
            ResultStd = handle_subscribe_authz(SubscriptionStd, ClientId, State(Mode)),
            ResultShared = handle_subscribe_authz(SubscriptionShared, ClientId, State(Mode)),
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
    make_sample_config(Authn, Authz, Stat, make_sample_broker_idm()).

make_sample_config(Authn, Authz, Stat, Me) ->
    #config{
        id=Me,
        authn=Authn,
        authz=Authz,
        stat=Stat}.

make_sample_session() ->
    make_sample_session(default).

make_sample_session(Mode) ->
    #session{
        id= <<"00000000-0000-0000-0000-000000000010">>,
        parent_id= <<"00000000-0000-0000-0000-000000000000">>,
        mode=Mode,
        version= ?VER,
        created_at=0}.

make_sample_broker_session() ->
    #session{
        id= <<"00000000-0000-0000-0000-000000000000">>,
        parent_id= <<"00000000-0000-0000-0000-000000000000">>,
        mode=service,
        version= ?VER,
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

make_sample_broker_config(IdMAud, Trusted) ->
    IdM = #{label => <<"alpha">>, account_id => #{label => <<"mqtt-gateway">>, audience => IdMAud}},
    Config =
        #{IdMAud =>
          #{type => trusted,
            trusted => gb_sets:from_list(Trusted)}},

    #{me => IdM,
      config => Config}.

make_sample_broker_idm(Aud) ->
    #{label => <<"alpha">>,
      account_id =>
        #{label => <<"mqtt-gateway">>,
          audience => Aud}}.

make_sample_broker_idm() ->
    make_sample_broker_idm(<<"example.org">>).

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
            service -> <<Version/binary, "/service-agents">>;
            observer -> <<Version/binary, "/observer-agents">>;
            bridge -> <<Version/binary, "/bridge-agents">>
        end,

    <<ModeLabel/binary, $/, AgentId/binary>>.

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
                properties = update_sample_message_properties(Mode, Properties)};
        _ ->
            error({bad_mode, Mode})
    end.

update_sample_message_properties(Mode, Properties) ->
    DefaultSampleUserProperties =
        #{ <<"agent_label">> => <<"test-1">>,
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
