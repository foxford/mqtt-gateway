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
    mqttgw_ratelimitstate:new(),
    ok = mqttgw_http:start(mqttgw_authn:read_config()),
    mqttgw_sup:start_link().

stop(_State) ->
    ok.
