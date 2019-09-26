-module(mqttgw_app).

-behaviour(application).

%% Application callbacks
-export([
    start/2,
    stop/1
]).

%% =============================================================================
%% Application callbacks
%% =============================================================================

start(_StartType, _StartArgs) ->
    mqttgw_state:new(),
    %% TODO: remove the local state
    %% START >>>>>
    %% This redundant behavior hopefully will be unnecessary with resolving of the 'issue:1326'.
    %% https://github.com/vernemq/vernemq/issues/1326
    mqttgw_dynsubstate:new(),
    %% <<<<< END
    mqttgw_sup:start_link().

stop(_State) ->
    ok.
