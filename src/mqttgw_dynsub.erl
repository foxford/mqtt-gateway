-module(mqttgw_dynsub).

%% API
-export([
    list/1
]).

%% Types
-type subject() :: mqttgw:connection().
-type object()  :: [binary()].
-type data()    :: #{app := binary(), object := object(), version := binary()}.

-export_types([subject/0, object/0, data/0]).

%% =============================================================================
%% API
%% =============================================================================

-spec list(subject()) -> [data()].
list(Subject) ->
    filter(vmq_subscriber_db:read({"", Subject})).

%% =============================================================================
%% Internal functions
%% =============================================================================

filter(undefined) ->
    [];
filter(L) ->
    lists:flatmap(fun({_, _, S}) ->
        lists:foldl(
            fun
                ({[<<"apps">>, App, <<"api">>, Ver | Object] = T, _Qos}, Acc) ->
                    Data =
                        #{app => App,
                          object => Object,
                          version => Ver},
                    [{T, Data} | Acc];
                (_, Acc) ->
                    Acc
            end,
            [], S)
        end,
        L).
