-module(mqttgw_http).
-export([start/1, stop/0]).

start(AuthnConfig) ->
	Dispatch = cowboy_router:compile([
		{'_', [
			{"/api/v1/subscriptions", mqttgw_http_subscription, AuthnConfig}
		]}
	]),
	{ok, _} = cowboy:start_clear(mqttgw_http, [{port, 8081}], #{
		env => #{dispatch => Dispatch}
	}),
	ok.

stop() ->
	ok = cowboy:stop_listener(mqttgw_http).
