-module(mqttgw_dyn_srv).
-behaviour(gen_server).

-export([
    init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3
]).

-export([
    start/0, stop/0, create_dynsub/3,
    authz_subscription_topic/1, delete_dynsub/3, delete_dynsub/2
]).

start() -> gen_server:start_link({global, {?MODULE, node()}}, ?MODULE, [], []).
stop() -> gen_server:stop({global, {?MODULE, node()}}).

create_dynsub(Subject, Data, DynsubRespData) ->
    CurrentNode = node(),
    case vmq_subscriber_db:read({[], Subject}) of
        %% no subject in subscriber_db, so we got nobody to subscribe to a given topic
        undefined ->
            error_logger:error_msg(
                "Error on publish: subject was not in vmq_subscriber_db, data: ~p",
                [Subject, Data]),
            {error, #{reason_code => impl_specific_error}};
        %% if the subject is subscribed on multiple nodes something went wrong
        %% since we disallow same agent ids
        NodeSubs when length(NodeSubs) > 1 ->
            error_logger:error_msg(
                "Error on publish: subject was subscribed to "
                "multiple nodes simultaneously, data: ~p",
                [Data]),
            {error, #{reason_code => impl_specific_error}};
        %% happy case when subject is on the same node as we are
        [{Node, _, _Subs}] when Node == CurrentNode ->
            error_logger:info_msg("Single node sub: ~p ~p", [Subject, Data]),
            %% TODO: in theory we could just subscribe directly here
            %% with following code without doing casts through genserver
            %%
            %% BUT it seems it causes race in calls to vmq_reg:subscribe()
            %% especially when the client tries to subscribe to two services across two nodes
            %% and the services override each other's subs
            %% since one creates a sub inside the genserver and
            %% another inside the on_publish hook thus concurrency
            %%
            %% THE SOLUTION is to do this through the genserver anyway
            %% so it runs in a singlethreaded manner

            % create_sub(Subject, Data),
            % {CorrData, RespTopic, SenderConn, SenderId,
            %     UniqueId, SessionPairId, Time} = DynsubRespData,

            % %% Send a response to the application.
            % mqttgw:send_dynsub_response(
            %     CorrData, RespTopic, SenderConn, SenderId,
            %     UniqueId, SessionPairId, Time),
            % error_logger:error_msg("Current subs: ~p", [vmq_subscriber_db:read({[], Subject})]),
            Topic = authz_subscription_topic(Data),
            register_dynsub(Node, Subject, Topic, Data, DynsubRespData),
            ok;
        %% Subject is on a different node, we need to create dynsub on that node.
        [{Node, _, _Subs}] ->
            error_logger:info_msg("Multi node sub: ~p ~p", [Subject, Data]),
            Topic = authz_subscription_topic(Data),
            register_dynsub(Node, Subject, Topic, Data, DynsubRespData),
            ok
    end.


delete_dynsub(Subject, Data, DynsubRespData) ->
    CurrentNode = node(),
    case vmq_subscriber_db:read({[], Subject}) of
        %% no subject in subscriber_db, so we got nobody to subscribe to a given topic
        undefined ->
            error_logger:error_msg(
                "Error on publish: subject was not in vmq_subscriber_db, subject: ~p, data: ~p",
                [Subject, Data]),
            {error, #{reason_code => impl_specific_error}};
        %% if the subject is subscribed on multiple nodes something went wrong
        %% since we disallow same agent ids
        NodeSubs when length(NodeSubs) > 1 ->
            error_logger:error_msg(
                "Error on publish: subject was subscribed to "
                "multiple nodes simultaneously, data: ~p",
                [Data]),
            {error, #{reason_code => impl_specific_error}};
        %% happy case when subject is on the same node as we are
        [{Node, _, _Subs}] when Node == CurrentNode ->
            %% TODO: same as with create_dynsub earlier
            %% delete_dynsub(Subject, Data),
            %% send_dynsub_del_response(Subject, Data, DynsubRespData),
            Topic = authz_subscription_topic(Data),
            remove_dynsub(Node, Subject, Topic, Data, DynsubRespData),
            ok;
        %% Subject is on a different node, we need to delete the dynsub on that node.
        [{Node, _, _Subs}] ->
            Topic = authz_subscription_topic(Data),
            remove_dynsub(Node, Subject, Topic, Data, DynsubRespData),
            ok
    end.

register_dynsub(Node, Subject, Topic, Data, DynsubRespData) ->
    gen_server:cast(
        {global, {?MODULE, Node}},
        {register_dynsub, Subject, Topic, Data, DynsubRespData, node()}
    ).

register_dynsub_creation_in_progress(Node, Subject, Topic, DynsubRespData) ->
    gen_server:cast(
        {global, {?MODULE, Node}},
        {register_dynsub_creation_in_progress, Subject, Topic, DynsubRespData}
    ).

remove_dynsub(Node, Subject, Topic, Data, DynsubRespData) ->
    gen_server:cast(
        {global, {?MODULE, Node}},
        {remove_dynsub, Subject, Topic, Data, DynsubRespData, node()}
    ).

register_dynsub_removal_in_progress(Node, Subject, Topic, Data, DynsubRespData) ->
    gen_server:cast(
        {global, {?MODULE, Node}},
        {register_dynsub_removal_in_progress, Subject, Topic, Data, DynsubRespData}
    ).

-spec authz_subscription_topic(mqttgw_dynsub:data()) -> mqttgw:topic().
authz_subscription_topic(Data) ->
    #{app := App,
      object := Object,
      version := Version} = Data,
    [<<"apps">>, App, <<"api">>, Version | Object].

-spec create_sub(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
create_sub(Subject, Data) ->
    QoS = 1,
    Topic = authz_subscription_topic(Data),
    mqttgw_broker:subscribe(Subject, [{Topic, QoS}]),

    error_logger:info_msg(
        "Dynamic subscription: ~p has been created "
        "for the subject = '~s'",
        [Data, Subject]),

    ok.

-spec delete_dynsub(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
delete_dynsub(Subject, Data) ->
    Topic = authz_subscription_topic(Data),
    mqttgw_broker:unsubscribe(Subject, [Topic]),

    error_logger:info_msg(
        "Dynamic subscription: ~p has been deleted "
        "for the subject = '~s'",
        [Data, Subject]),

    ok.

init([]) ->
    EHandler = vmq_subscriber_db:subscribe_db_events(),
    State = #{event_handler => EHandler, subs_queue => #{}, removals_queue => #{}},
    {ok, State}.

handle_cast({register_dynsub, Subject, Topic, Data, DynsubRespData, From}, State) ->
    register_dynsub_creation_in_progress(From, Subject, Topic, DynsubRespData),
    create_sub(Subject, Data),
    {noreply, State};
handle_cast(
    {register_dynsub_creation_in_progress, Subject, Topic, DynsubRespData},
    #{subs_queue := SubsQueue} = State) ->
    %% if the topic is not in subscriptions we need to wait
    %% for an event from vmq_metadata and send reply in the event handler

    %% if the topic is then the event already arrived earlier
    %% so we can just send reply here since it was not sent before
    case vmq_subscriber_db:read({[], Subject}) of
        undefined ->
            SubscriberQ = maps:get(Subject, SubsQueue, #{}),
            NewState = State#{
                subs_queue => SubsQueue#{
                    Subject => SubscriberQ#{
                        Topic => DynsubRespData}}},
            {noreply, NewState};
        [{_Node, _, Subs}] ->
            case search_topic_in_subs(Subs, Topic) of
                {value, _Val} ->
                    send_dynsub_response(DynsubRespData),
                    {noreply, State};
                false ->
                    SubscriberQ = maps:get(Subject, SubsQueue, #{}),
                    NewState = State#{
                        subs_queue => SubsQueue#{
                            Subject => SubscriberQ#{
                                Topic => DynsubRespData}}},
                    {noreply, NewState}
            end
    end;
handle_cast(
    {remove_dynsub, Subject, Topic, Data, DynsubRespData, From},
    State) ->
    register_dynsub_removal_in_progress(From, Subject, Topic, Data, DynsubRespData),
    delete_dynsub(Subject, Data),
    {noreply, State};
handle_cast(
    {register_dynsub_removal_in_progress, Subject, Topic, Data, DynsubRespData},
    #{removals_queue := RemsQueue} = State) ->
    %% if the topic is not in subscriptions then the event already arrived earlier and
    %% subscription was deleted so we can just send reply here since it was not sent before
    %%
    %% if the topic is still here then we need to wait for an event
    %% from vmq_metadata and send reply in the event handler
    case vmq_subscriber_db:read({[], Subject}) of
        undefined ->
            send_dynsub_del_response(Subject, Data, DynsubRespData),
            {noreply, State};
        [{_Node, _, Subs}] ->
            case search_topic_in_subs(Subs, Topic) of
                {value, _Val} ->
                    SubscriberQ = maps:get(Subject, RemsQueue, #{}),
                    NewState = State#{
                        removals_queue => RemsQueue#{
                            Subject => SubscriberQ#{
                                Topic => {Subject, Data, DynsubRespData}}}},
                    {noreply, NewState};
                false ->
                    send_dynsub_del_response(Subject, Data, DynsubRespData),
                    {noreply, State}
            end
    end;
handle_cast(_Message, State) -> {noreply, State}.

handle_info(Event,
    #{event_handler := Handler, subs_queue := SubsQueue, removals_queue := RemsQueue} = State) ->
    {NewSubsQueue, NewRemsQueue} = handle_event(Handler, Event, SubsQueue, RemsQueue),
    NewState = State#{subs_queue => NewSubsQueue, removals_queue => NewRemsQueue},
    {noreply, NewState}.

handle_event(Handler, Event, SubsQueue, RemsQueue) ->
    case Handler(Event) of
        {update, {_MountPoint, AgentId}, [{_Node, _, OldSubs}], [{_Node, _, NewSubs}]} ->
            NewSubsQueue = case maps:find(AgentId, SubsQueue) of
                error ->
                    SubsQueue;
                {ok, Additions} ->
                    AddedSubs = lists:subtract(NewSubs, OldSubs),
                    UpdatedAdditions = lists:foldl(fun addition_fold/2,
                        Additions,
                        AddedSubs),
                    maps:put(AgentId, UpdatedAdditions, SubsQueue)
            end,
            NewRemsQueue = case maps:find(AgentId, RemsQueue) of
                error ->
                    RemsQueue;
                {ok, Removals} ->
                    RemovedSubs = lists:subtract(OldSubs, NewSubs),
                    UpdatedRemovals = lists:foldl(fun removal_fold/2,
                        Removals,
                        RemovedSubs),
                    maps:put(AgentId, UpdatedRemovals, RemsQueue)
            end,
            {NewSubsQueue, NewRemsQueue};
        _ ->
            {SubsQueue, RemsQueue}
    end.

handle_call(_Message, _From, State) -> {reply, ok, State}.


terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

addition_fold({Topic, _Qos}, Acc) ->
    case maps:find(Topic, Acc) of
        error -> Acc;
        {ok, DynsubRespData} ->
            send_dynsub_response(DynsubRespData),
            maps:remove(Topic, Acc)
    end.


removal_fold({Topic, _Qos}, Acc) ->
    case maps:find(Topic, Acc) of
        error -> Acc;
        {ok, {Subject, Data, DynsubRespData}} ->
            send_dynsub_del_response(Subject, Data, DynsubRespData),
            maps:remove(Topic, Acc)
    end.

send_dynsub_response({CorrData, RespTopic, SenderConn, SenderId,
            UniqueId, SessionPairId, Time}) ->
    mqttgw:send_dynsub_response(
        CorrData, RespTopic, SenderConn, SenderId,
        UniqueId, SessionPairId, Time).

send_dynsub_del_response(Subject, Data, {CorrData, RespTopic, SenderConn, SenderId,
                UniqueId, SessionPairId, Time}) ->
    %% Send a response to the application.
    mqttgw:send_dynsub_response(
        CorrData, RespTopic, SenderConn, SenderId,
        UniqueId, SessionPairId, Time),

    %% Send a multicast event to the application
    mqttgw:send_dynsub_multicast_event(
        <<"subscription.delete">>, Subject, Data, SenderConn, SenderId,
        UniqueId, SessionPairId, Time).

search_topic_in_subs(Subs, Topic) ->
    lists:search(fun({T, _}) -> T == Topic end, Subs).
