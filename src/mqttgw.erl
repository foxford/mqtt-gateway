%% -----------------------------------------------------------------------------
%% The MIT License
%%
%% Copyright (c) 2018 Andrei Nesterov <ae.nesterov@gmail.com>
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to
%% deal in the Software without restriction, including without limitation the
%% rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
%% sell copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%% IN THE SOFTWARE.
%% -----------------------------------------------------------------------------

-module(mqttgw).

-behaviour(auth_on_register_hook).
-behaviour(auth_on_subscribe_hook).
-behaviour(auth_on_publish_hook).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Plugin callbacks
-export([
    auth_on_register/5,
    auth_on_publish/6,
    auth_on_subscribe/3
]).

%% API
-export([
    mqtt_connection/0,
    make_agent_label/0,
    make_agent_state/1,
    client_id/1
]).

%% Configuration
-export([
    account_id/0,
    mqtt_connection_options/1,
    environment_variable_to_binary/1,
    environment_variable_to_binary/2
]).

%% Types
-type agent_id() :: #{account_id => binary(), label => binary()}.
-type agent_state() ::
    #{agent_id := agent_id(),
      token := binary(),
      state := idle | active}.

%% =============================================================================
%% Plugin callbacks
%% =============================================================================

auth_on_register(
    _Peer, {_MountPoint, ClientId} = _SubscriberId, _Username,
    _Password, _CleanSession) ->

    try validate_agent_id(ClientId) of
        #{account_id := AccountId, label := Label} ->
            error_logger:info_msg(
                "Agent connected: account_id=~s, label=~s",
                [AccountId, Label]),
            ok
    catch
        T:R ->
            error_logger:warning_msg(
                "Agent failed to connect: client_id=~p, "
                "exception_type=~p, excepton_reason=~p",
                [ClientId, T, R]),
            {error, invalid_credentials}
    end.

auth_on_publish(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _QoS, _Topic, Payload, _IsRetain) ->

    #{account_id := AccountId,
      label := Label} = AgentId = parse_agent_id(ClientId),

    try envelope(AgentId, Payload) of
        Envelope ->
            {ok, [{payload, Envelope}]}
    catch
        T:R ->
            error_logger:error_msg(
                "Agent failed to publish: "
                "account_id=~s, label=~s, message=~p, "
                "exception_type=~p, excepton_reason=~p",
                [AccountId, Label, Payload, T, R]),
            {error, bad_payload}
    end.

auth_on_subscribe(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Topics) ->

    #{account_id := AccountId,
      label := Label} = parse_agent_id(ClientId),

    error_logger:info_msg(
        "Agent subscribed: account_id=~s, label=~s, topics=~p",
        [AccountId, Label, Topics]),

    ok.

-spec client_id(agent_id()) -> binary().
client_id(#{account_id := AccountId, label := Label}) ->
    <<AccountId/binary, $., Label/binary>>.

%% =============================================================================
%% API
%% =============================================================================

-spec mqtt_connection() -> pid().
mqtt_connection() ->
    element(2, lists:keyfind(mqtt_connection, 1, supervisor:which_children(mqttgw_sup))).

-spec make_agent_label() -> binary().
make_agent_label() ->
    base64:encode(crypto:strong_rand_bytes(16)).

-spec make_agent_state(agent_id()) -> agent_state().
make_agent_state(AgentId) ->
    #{agent_id => AgentId,
      token => crypto:strong_rand_bytes(16),
      state => idle}.

%% =============================================================================
%% Configuration
%% =============================================================================

-spec account_id() -> binary().
account_id() ->
    environment_variable_to_binary("ACCOUNT_ID").

-spec mqtt_url() -> binary().
mqtt_url() ->
    environment_variable_to_binary("MQTT_URL", <<"mqtt://localhost:1883">>).

-spec mqtt_connection_options(binary()) -> list().
mqtt_connection_options(ClientId) ->
    Default = [
        {clean_sess, true},
        {logger, {lager, info}},
        {reconnect, 5}
    ],

    {Scheme, _UserInfo, Host, Port, _Path, _Query} =
        case http_uri:parse(binary_to_list(mqtt_url())) of
            {ok, Val}      -> Val;
            {error, Reason} -> error({bad_mqtt_uri, Reason})
        end,
    EnvL =
        [ {host, Host},
          {port, Port},
          {client_id, ClientId} ]
        ++ case Scheme of
            mqtts -> [ssl];
            _     -> []
        end,

    Opts = application:get_env(mediagw, mqtt_connection_options, Default),
    lists:foldl(
        fun({Key, _} =Param, Acc) ->
            lists:keystore(Key, 1, Acc, Param)
        end, Opts, EnvL).

-spec environment_variable_to_binary(nonempty_string()) -> binary().
environment_variable_to_binary(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment_variable, Name});
        Val   -> list_to_binary(Val)
    end.

-spec environment_variable_to_binary(nonempty_string(), binary()) -> binary().
environment_variable_to_binary(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Val   -> list_to_binary(Val)
    end.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec validate_agent_id(binary()) -> agent_id().
validate_agent_id(Val) ->
    AgentId =
        #{account_id := AccountId,
            label := Label} = parse_agent_id(Val),
    true = uuid:is_uuid(uuid:string_to_uuid(AccountId)),
    true = is_binary(Label),
    AgentId.

-spec parse_agent_id(binary()) -> agent_id().
parse_agent_id(<<AccountId:36/binary, $., Label/binary>>) ->
    #{account_id => AccountId, label => Label}.

-spec envelope(agent_id(), binary()) -> jsx:json_term().
envelope(AgentId, Message) ->
    jsx:encode(
        #{sub => AgentId,
          msg => Message}).

%% =============================================================================
%% Tests
%% =============================================================================

-ifdef(TEST).

uuid_t() ->
    ?LET(Val, uuid:uuid_to_string(uuid:get_v4(), binary_standard), Val).

client_id_t() ->
    ?LET(
        {AccountId, Label},
        {uuid_t(), binary_utf8_t()},
        <<AccountId/binary, $., Label/binary>>).

subscriber_id_t() ->
    ?LET(
        {MountPoint, ClientId},
        {string(), client_id_t()},
        {MountPoint, ClientId}).

binary_utf8_t() ->
    ?LET(Val, string(), unicode:characters_to_binary(Val, utf8, utf8)).

%% Excluding multi-level '#' and single-level '+' wildcards
publish_topic_t() ->
    ?LET(
        Val,
        list(union([
            integer(0, 34),
            integer(36, 42),
            integer(44, 16#10ffff)
        ])),
        unicode:characters_to_binary(Val, utf8, utf8)).

subscribe_topic_t() ->
    ?LET(Val, binary_utf8_t(), Val).

qos_t() ->
    ?LET(Val, integer(0, 2), Val).

prop_onconnect() ->
    ?FORALL(
        {Peer, SubscriberId, Username, Password, CleanSession},
        {any(), subscriber_id_t(), binary_utf8_t(), binary_utf8_t(), boolean()},
        ok =:= auth_on_register(Peer, SubscriberId, Username, Password, CleanSession)).

prop_onconnect_invalid_credentials() ->
    ?FORALL(
        {Peer, MountPoint, ClientId, Username, Password, CleanSession},
        {any(), string(), binary(32), binary_utf8_t(), binary_utf8_t(), boolean()},
        {error, invalid_credentials} =:=
            auth_on_register(Peer, {MountPoint, ClientId}, Username, Password, CleanSession)).

prop_onpublish() ->
    ?FORALL(
        {Username, SubscriberId, QoS, Topic, Payload, IsRetain},
        {binary_utf8_t(), subscriber_id_t(),
         qos_t(), publish_topic_t(), binary_utf8_t(), boolean()},
        begin
            AgentId = parse_agent_id(element(2, SubscriberId)),
            {ok, Modifiers} =
                auth_on_publish(Username, SubscriberId, QoS, Topic, Payload, IsRetain),
            {_, Envelope} = lists:keyfind(payload, 1, Modifiers),
            Envelope =:= envelope(AgentId, Payload)
        end).

prop_onsubscribe() ->
    ?FORALL(
        {Username, SubscriberId, Topics},
        {binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        ok =:= auth_on_subscribe(Username, SubscriberId, Topics)).

-endif.
