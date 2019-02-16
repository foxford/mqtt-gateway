-module(mqttgw_sup).
-behaviour(supervisor).

%% API
-export([
    start_link/0
]).

%% Supervisor callbacks
-export([
    init/1
]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    Flags = #{},
    Procs = [],
    {ok, {Flags, Procs}}.
