-module(mqttgw_dynsubstate).

%% API
-export([
    new/0,
    get/1,
    put/2,
    remove/1,
    remove/2,
    erase/0,
    foreach/1
]).

%% Types
-record(subscription, {
    key :: mqttgw_dynsub:subject(),
    val :: mqttgw_dynsub:data()
}).

%% Definitions
-define(SUBSCR_TABLE, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> ok.
new() ->
    catch _ = ets:new(
        ?SUBSCR_TABLE,
        [ bag, public, named_table,
          {keypos, #subscription.key} ]),
    ok.

-spec get(mqttgw_dynsub:subject()) -> [mqttgw_dynsub:data()].
get(Subject) ->
    [Data || #subscription{val=Data} <- ets:lookup(?SUBSCR_TABLE, Subject)].

-spec put(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
put(Subject, Data) ->
    ets:insert(?SUBSCR_TABLE, #subscription{key=Subject, val=Data}),
    ok.

-spec remove(mqttgw_dynsub:subject()) -> ok.
remove(Subject) ->
    ets:delete(?SUBSCR_TABLE, Subject),
    ok.

-spec remove(mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok.
remove(Subject, Data) ->
    ets:delete_object(?SUBSCR_TABLE, #subscription{key=Subject, val=Data}),
    ok.

-spec erase() -> ok.
erase() ->
    ets:delete_all_objects(?SUBSCR_TABLE),
    ok.

-spec foreach(fun((mqttgw_dynsub:subject(), mqttgw_dynsub:data()) -> ok)) -> ok.
foreach(F) ->
    ets:foldl(
        fun(#subscription{key=Subject, val=Data}, Acc) ->
            F(Subject, Data),
            Acc
        end, ok, ?SUBSCR_TABLE).
