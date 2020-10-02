-module(mqttgw_ratelimitstate).

%% API
-export([
    new/0,
    get_dirty/1,
    get/2,
    put_dirty/2,
    put/4,
    erase/0
]).

%% Types
-type constraints() ::
    #{message_count := non_neg_integer(),
      byte_count := non_neg_integer()}.
-type data() ::
    #{time := non_neg_integer(),
      bytes := non_neg_integer()}.
-type error_reason() :: {atom(), non_neg_integer()}.
-type result() ::
    #{messages := [data()],
      message_count := non_neg_integer(),
      byte_count := non_neg_integer()}.

-record(item, {
    key :: mqttgw_id:agent_id(),
    val :: [data()]
}).

-export_types([data/0, result/0]).

%% Definitions
-define(AGENT_TABLE, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> ok.
new() ->
    catch _ = ets:new(
        ?AGENT_TABLE,
        [ set, public, named_table,
          {keypos, #item.key} ]),
    ok.

-spec get_dirty(mqttgw_id:agent_id()) -> [data()].
get_dirty(AgentId) ->
    case ets:lookup(?AGENT_TABLE, AgentId) of
        [#item{val=L}] -> L;
        _ -> []
    end.

-spec get(mqttgw_id:agent_id(), non_neg_integer()) -> result().
get(AgentId, Time) ->
    L = lists:filter(fun(#{time := T}) -> T > Time end, get_dirty(AgentId)),
    BytesCount = lists:foldl(fun(#{bytes := B}, Acc) -> Acc + B end, 0, L),
    MessageCount = length(L),
    #{messages => L,
      message_count => MessageCount,
      byte_count => BytesCount}.

-spec put_dirty(mqttgw_id:agent_id(), data()) -> ok.
put_dirty(AgentId, Data) ->
    L = get_dirty(AgentId),
    Item = #item{key=AgentId, val=[Data|L]},
    ets:insert(?AGENT_TABLE, Item),
    ok.

-spec put(mqttgw_id:agent_id(), data(), non_neg_integer(), constraints())
    -> ok | {error, error_reason()}.
put(AgentId, Data, Time, Constraints) ->
    #{bytes := Bytes} = Data,
    #{message_count := MessageCountLimit,
      byte_count := ByteCountLimit} = Constraints,
    case get(AgentId, Time) of
        #{message_count := MessageCount} when (MessageCount + 1) > MessageCountLimit ->
            {error, {message_rate_exceeded, MessageCount + 1}};
        #{byte_count := ByteCount} when (ByteCount + Bytes) > ByteCountLimit ->
            {error, {byte_rate_exceeded, ByteCount + Bytes}};
        #{messages := L} ->
            Item = #item{key=AgentId, val=[Data|L]},
            ets:insert(?AGENT_TABLE, Item),
            ok
    end.

-spec erase() -> ok.
erase() ->
    ets:delete_all_objects(?AGENT_TABLE),
    ok.
