-module(mqttgw_state).

%% API
-export([
    new/0,
    get/1,
    find/1,
    put/2
]).

%% Types
-record(state, {
    key,
    value
}).

%% Definitions
-define(STATE_TABLE, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> ok.
new() ->
    catch _ = ets:new(
        ?STATE_TABLE,
        [ set, public, named_table,
          {keypos, #state.key},
          {read_concurrency, true} ]),
    ok.

-spec get(any()) -> any().
get(Key) ->
    case find(Key) of
        {ok, Val} -> Val;
        _ -> error({missing_state_key, Key})
    end.

-spec find(any()) -> {ok, any()} | error.
find(Key) ->
    case ets:lookup(?STATE_TABLE, Key) of
        [#state{value = Val}] -> {ok, Val};
        _ -> error
    end.

-spec put(any(), any()) -> ok.
put(Key, Val) ->
    ets:insert(?STATE_TABLE, #state{key=Key, value=Val}),
    ok.
