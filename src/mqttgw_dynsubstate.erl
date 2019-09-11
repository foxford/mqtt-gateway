-module(mqttgw_dynsubstate).

%% API
-export([
    new/0,
    get/1,
    put/2,
    remove/1,
    erase/0,
    foreach/1
]).

%% Types
-type subject() :: binary().
-type object()  :: [binary()].
-type data() :: #{object := object(), app := binary()}.

-record(subscription, {
    key :: subject(),
    val :: data()
}).

-export_types([subject/0, object/0]).

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

-spec get(subject()) -> [data()].
get(Subject) ->
    [Data || #subscription{val=Data} <- ets:lookup(?SUBSCR_TABLE, Subject)].

-spec put(subject(), data()) -> ok.
put(Subject, Data) ->
    ets:insert(?SUBSCR_TABLE, #subscription{key=Subject, val=Data}),
    ok.

-spec remove(subject()) -> ok.
remove(Subject) ->
    ets:delete(?SUBSCR_TABLE, Subject),
    ok.

-spec erase() -> ok.
erase() ->
    ets:delete_all_objects(?SUBSCR_TABLE),
    ok.

-spec foreach(fun((subject(), data()) -> ok)) -> ok.
foreach(F) ->
    ets:foldl(
        fun(#subscription{key=Subject, val=Data}, Acc) ->
            F(Subject, Data),
            Acc
        end, ok, ?SUBSCR_TABLE).
