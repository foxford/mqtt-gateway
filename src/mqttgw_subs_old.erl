-module(mqttgw_subs_old).

-define(VER_2, <<"v2">>).
-define(BROKER_CONNECTION, #connection{mode=service, version=?VER_2}).

%% Types
-type topic() :: [binary()].
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
    id         :: mqttgw_id:agent_id(),
    authn      :: disabled | {enabled, mqttgw_authn:config()},
    authz      :: disabled | {enabled, mqttgw_authz:config()},
    dynsub     :: disabled | enabled,
    stat       :: disabled | enabled,
    rate_limit :: disabled | {enabled, mqttgw_ratelimit:config()}
}).
-type config() :: #config{}.

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

-export([handle_deliver_dynsub_config/4, delete_client_dynsubs/6]).

-spec handle_deliver_dynsub_config(topic(), message(), mqttgw_id:agent_id(), state()) -> message().
handle_deliver_dynsub_config(Topic, Message, RecvId, State) ->
    case State#state.config#config.dynsub of
        disabled ->
            Message;
        enabled ->
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
                case catch mqttgw:parse_agent_id(Subject) of
                    RecvId ->
                        handle_deliver_broker_dynsub_create_request(
                            Version, App, Object, Subject,
                            CorrData, BrokerId, AgentId, State);
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
                case catch mqttgw:parse_agent_id(Subject) of
                    RecvId ->
                        handle_deliver_broker_dynsub_delete_request(
                            Version, App, Object, Subject,
                            CorrData, BrokerId, AgentId, State);
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

-spec handle_deliver_broker_dynsub_create_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_broker_dynsub_create_request(
    Version, App, Object, Subject, CorrData, BrokerId, AgentId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = mqttgw:format_session_id(SessionId, ParentSessionId),

    %% Subscribe the agent to the app's topic and send a success response
    Data = #{app => App, object => Object, version => Version},
    create_dynsub(Subject, Data),

    %% Send a multicast event to the application
    mqttgw:send_dynsub_multicast_event(
        <<"subscription.create">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    %% NOTE: only 'service' is allowed to send a dynsub request and all the senders use 'v2'.
    SenderConn = #connection{version=?VER_2, mode=service},
    create_dynsub_response(
        CorrData, BrokerId, SenderConn, AgentId,
        UniqueId, SessionPairId, Time).

-spec handle_deliver_broker_dynsub_delete_request(
    binary(), binary(), mqttgw_dynsub:object(), mqttgw_dynsub:subject(),
    binary(), mqttgw_id:agent_id(), mqttgw_id:agent_id(), state())
    -> message().
handle_deliver_broker_dynsub_delete_request(
    Version, App, Object, Subject, CorrData, BrokerId, AgentId, State) ->
    #state{
        time=Time,
        unique_id=UniqueId,
        session=#session{id=SessionId, parent_id=ParentSessionId}} = State,
    SessionPairId = mqttgw:format_session_id(SessionId, ParentSessionId),

    %% Unsubscribe the agent from the app's topic and send a success response
    Data = #{app => App, object => Object, version => Version},
    delete_dynsub(Subject, Data),

    %% Send a multicast event to the application
    mqttgw:send_dynsub_multicast_event(
        <<"subscription.delete">>, Subject, Data, ?BROKER_CONNECTION, BrokerId,
        UniqueId, SessionPairId, Time),

    %% Send an unicast response to the 3rd-party agent
    %% NOTE: only 'service' is allowed to send a dynsub request and all the senders use 'v2'.
    SenderConn = #connection{version=?VER_2, mode=service},
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
            mqttgw:validate_message_properties(
                mqttgw:update_message_properties(
                    #{p_correlation_data => CorrData,
                        p_user_property =>
                        [ {<<"type">>, <<"response">>},
                          {<<"status">>, <<"202">>} ]},
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
    {_, ConnMode} = lists:keyfind(<<"connection_mode">>, 1, UserProperties),
    {_, AgentIdB} = lists:keyfind(<<"agent_id">>, 1, UserProperties),
    AgentId = mqttgw:parse_agent_id(AgentIdB),

    #{type => Type,
      method => Method,
      connection_mode => mqttgw:parse_connection_mode(ConnMode),
      correlation_data => CorrData,
      response_topic => RespTopic,
      sent_by => AgentId}.

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

    error_logger:error_msg(
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

    error_logger:error_msg(
        "Dynamic subscription: ~p has been deleted "
        "for the subject = '~s'",
        [Data, Subject]),

    ok.

-spec authz_subscription_topic(mqttgw_dynsub:data()) -> topic().
authz_subscription_topic(Data) ->
    #{app := App,
      object := Object,
      version := Version} = Data,
    [<<"apps">>, App, <<"api">>, Version | Object].

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
    [mqttgw:send_dynsub_multicast_event(
        <<"subscription.delete">>, Subject, Data, BrokerConn, BrokerId,
        UniqueId, SessionPairId, Time)
     || Data <- DynSubL],

    %% Remove subscriptions
    [delete_dynsub(Subject, Data) || Data  <- DynSubL],

    ok.
