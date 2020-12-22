-module(mqttgw_broker).

%% API
-export([
    list_connections/0,
    subscribe/2,
    unsubscribe/2,
    publish/3
]).

%% =============================================================================
%% API
%% =============================================================================

-spec list_connections() -> [mqttgw:connection()].
list_connections() ->
    vmq_subscriber_db:fold(
        fun
            ({{_, Subject}, _}, Acc) ->
                [Subject|Acc];
            (Item, Acc) ->
                error_logger:error_msg(
                    "Error retrieving a list of the broker connections: "
                    "invalid format of the list item = '~p', "
                    "the item is ignored",
                    [Item]),
                Acc
        end,
        []).

%% Create a subscription for the particular client.
%% We can verify the fact that subscription has been created by calling:
%% vmq_subscriber_db:read({"", ClientId}).

subscribe(ClientId, Topics) ->
    wait_til_ready(),
    CAPSubscribe = vmq_config:get_env(allow_subscribe_during_netsplit, false),
    vmq_reg:subscribe(CAPSubscribe, {"", ClientId}, Topics),
    ok.

unsubscribe(ClientId, Topics) ->
    wait_til_ready(),
    CAPSubscribe = vmq_config:get_env(allow_unsubscribe_during_netsplit, false),
    vmq_reg:unsubscribe(CAPSubscribe, {"", ClientId}, Topics),
    ok.

publish(Topic, Payload, QoS) ->
    {_, Publish, _} = vmq_reg:direct_plugin_exports(mqttgw),
    Publish(Topic, Payload, #{qos => QoS}),
    ok.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec wait_til_ready() -> ok.
wait_til_ready() ->
    case catch vmq_cluster:if_ready(fun() -> true end, []) of
        true ->
            ok;
        _ ->
            timer:sleep(100),
            wait_til_ready()
end.
