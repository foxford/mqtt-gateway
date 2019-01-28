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
-behaviour(auth_on_publish_hook).
-behaviour(on_deliver_hook).
-behaviour(auth_on_subscribe_hook).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Plugin callbacks
-export([
    auth_on_register/5,
    auth_on_publish/6,
    on_deliver/4,
    auth_on_subscribe/3
]).

%% Types
-type connection_mode() :: default | payload_only | bridge.

-record(client_id, {
    mode          :: connection_mode(),
    agent_label   :: binary(),
    account_label :: binary(),
    audience      :: binary()
}).
-type client_id() :: #client_id{}.

-record (envelope, {
    payload    :: binary(),
    properties :: map()
}).
-type envelope() :: #envelope{}.

%% =============================================================================
%% Plugin callbacks
%% =============================================================================

auth_on_register(
    _Peer, {_MountPoint, ClientId} = _SubscriberId, _Username,
    _Password, _CleanSession) ->

    try validate_client_id(parse_client_id(ClientId)) of
        #client_id{
            mode=Mode,
            agent_label=AgentLabel,
            account_label=AccountLabel,
            audience=Audience} ->
            error_logger:info_msg(
                "Agent connected: mode=~p, agent_label=~s, account_label=~s, audience=~s",
                [Mode, AgentLabel, AccountLabel, Audience]),
            ok
    catch
        T:R ->
            error_logger:warning_msg(
                "Agent failed to connect: invalid client_id=~p, "
                "exception_type=~p, exception_reason=~p",
                [ClientId, T, R]),
            {error, invalid_credentials}
    end.

auth_on_publish(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _QoS, _Topic, Payload, _IsRetain) ->

    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = parse_client_id(ClientId),

    try envelope(
            Mode, AgentLabel, AccountLabel, Audience,
            validate_envelope(parse_envelope(Mode, Payload))) of
        UpdatedPayload ->
            {ok, [{payload, UpdatedPayload}]}
    catch
        T:R ->
            error_logger:error_msg(
                "Agent failed to publish: invalid msg=~p, "
                "exception_type=~p, exception_reason=~p",
                [Payload, T, R]),
            {error, bad_payload}
    end.

on_deliver(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    _Topic, Payload) ->

    #client_id{mode=Mode} = parse_client_id(ClientId),

    try deliver_envelope(Mode, Payload) of
        UpdatedPayload ->
            {ok, [{payload, UpdatedPayload}]}
    catch
        T:R ->
            error_logger:error_msg(
                "Agent failed to publish: invalid msg=~p, "
                "exception_type=~p, exception_reason=~p",
                [Payload, T, R]),
            {error, bad_payload}
    end.

auth_on_subscribe(
    _Username, {_MountPoint, ClientId} = _SubscriberId,
    Topics) ->

    #client_id{
        mode=Mode,
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = parse_client_id(ClientId),

    error_logger:info_msg(
        "Agent subscribed: mode=~p, agent_label=~s, account_label=~s, audience=~s, topics=~p",
        [Mode, AgentLabel, AccountLabel, Audience, Topics]),

    ok.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec validate_client_id(client_id()) -> client_id().
validate_client_id(Val) ->
    #client_id{
        agent_label=AgentLabel,
        account_label=AccountLabel,
        audience=Audience} = Val,

    true = is_binary(AgentLabel),
    true = is_binary(AccountLabel),
    true = is_binary(Audience),
    Val.

-spec parse_client_id(binary()) -> client_id().
parse_client_id(<<"v1.mqtt3/agents/", R/bits>>) ->
    parse_v1_agent_label(R, default, <<>>);
parse_client_id(<<"v1.mqtt3.payload-only/agents/", R/bits>>) ->
    parse_v1_agent_label(R, payload_only, <<>>);
parse_client_id(<<"v1.mqtt3/bridge-agents/", R/bits>>) ->
    parse_v1_agent_label(R, bridge, <<>>).

-spec parse_v1_agent_label(binary(), connection_mode(), binary()) -> client_id().
parse_v1_agent_label(<<$., _/bits>>, _Mode, <<>>) ->
    error(missing_agent_label);
parse_v1_agent_label(<<$., R/bits>>, Mode, Acc) ->
    parse_v1_account_label(R, Mode, Acc, <<>>);
parse_v1_agent_label(<<C, R/bits>>, Mode, Acc) ->
    parse_v1_agent_label(R, Mode, <<Acc/binary, C>>);
parse_v1_agent_label(<<>>, _Mode, Acc) ->
    error({bad_client_id, [Acc]}).

-spec parse_v1_account_label(binary(), connection_mode(), binary(), binary()) -> client_id().
parse_v1_account_label(<<$., _/bits>>, _Mode, _AgentLabel, <<>>) ->
    error(missing_account_label);
parse_v1_account_label(<<$., R/bits>>, Mode, AgentLabel, Acc) ->
    parse_v1_audience(R, Mode, AgentLabel, Acc);
parse_v1_account_label(<<C, R/bits>>, Mode, AgentLabel, Acc) ->
    parse_v1_account_label(R, Mode, AgentLabel, <<Acc/binary, C>>);
parse_v1_account_label(<<>>, _Mode, AgentLabel, Acc) ->
    error({bad_client_id, [AgentLabel, Acc]}).

-spec parse_v1_audience(binary(), connection_mode(), binary(), binary()) -> client_id().
parse_v1_audience(<<>>, _Mode, _AgentLabel, _AccountLabel) ->
    error(missing_audience);
parse_v1_audience(Audience, Mode, AgentLabel, AccountLabel) ->
    #client_id{agent_label=AgentLabel, account_label=AccountLabel, audience=Audience, mode=Mode}.

-spec validate_authn_properties(map()) -> map().
validate_authn_properties(Properties) ->
    _ = validate_agent_label_property(Properties),
    _ = validate_account_label_property(Properties),
    _ = validate_audience_property(Properties),
    Properties.

-spec validate_agent_label_property(map()) -> binary().
validate_agent_label_property(#{<<"agent_label">> := Val}) when is_binary(Val) ->
    Val;
validate_agent_label_property(#{<<"agent_label">> := Val}) ->
    error({bad_agent_label, Val});
validate_agent_label_property(_) ->
    error(missing_agent_label).

-spec validate_account_label_property(map()) -> binary().
validate_account_label_property(#{<<"account_label">> := Val}) when is_binary(Val) ->
    Val;
validate_account_label_property(#{<<"account_label">> := Val}) ->
    error({bad_account_label, Val});
validate_account_label_property(_) ->
    error(missing_account_label).

-spec validate_audience_property(map()) -> binary().
validate_audience_property(#{<<"audience">> := Val}) when is_binary(Val) ->
    Val;
validate_audience_property(#{<<"audience">> := Val}) ->
    error({bad_audience, Val});
validate_audience_property(_) ->
    error(missing_audience).

-spec validate_envelope(envelope()) -> envelope().
validate_envelope(Val) ->
    #envelope{
        payload=Payload,
        properties=Properties} = Val,

    true = is_binary(Payload),
    true = is_map(Properties),
    Val.

-spec parse_envelope(connection_mode(), binary()) -> envelope().
parse_envelope(Mode, Message) when (Mode =:= default) or (Mode =:= bridge) ->
    Envelope = jsx:decode(Message, [return_maps]),
    Payload = maps:get(<<"payload">>, Envelope),
    Properties = maps:get(<<"properties">>, Envelope, #{}),
    #envelope{payload=Payload, properties=Properties};
parse_envelope(payload_only, Message) ->
    #envelope{payload=Message, properties=#{}}.

-spec envelope(connection_mode(), binary(), binary(), binary(), envelope()) -> binary().
envelope(Mode, AgentLabel, AccountLabel, Audience, Envelope) ->
    #envelope{
        payload=Payload,
        properties=Properties} = Envelope,

    %% Everything is "event" by default
    UpdatedProperties0 =
        case maps:find(<<"type">>, Properties) of
            error -> Properties#{<<"type">> => <<"event">>};
            _     -> Properties
        end,

    %% Override authn properties
    UpdatedProperties1 =
        case Mode of
            bridge ->
                %% We do not override authn properties for 'bridge' mode,
                %% but verify that they are exist
                validate_authn_properties(UpdatedProperties0);
            _ ->
                UpdatedProperties0#{
                    <<"agent_label">> => AgentLabel,
                    <<"account_label">> => AccountLabel,
                    <<"audience">> => Audience}
        end,

    jsx:encode(
        #{properties => UpdatedProperties1,
          payload => Payload}).

-spec deliver_envelope(connection_mode(), binary()) -> binary().
deliver_envelope(Mode, Payload) ->
    Envelope = validate_envelope(parse_envelope(default, Payload)),
    case Mode of
        Mode when (Mode =:= default) or (Mode =:= bridge) ->
            Payload;
        payload_only ->
            #envelope{payload=InnerPayload} = Envelope,
            InnerPayload
    end.

%% =============================================================================
%% Tests
%% =============================================================================

-ifdef(TEST).

version_t() ->
    ?LET(
        Index,
        choose(1, 2),
        lists:nth(Index, [<<"v1.mqtt3">>, <<"v1.mqtt3.payload-only">>])).

client_id_t() ->
    ?LET(
        {Version, AgentLabel, AccountLabel, Audience},
        {version_t(), label_t(), label_t(), label_t()},
        <<Version/binary,
          "/agents/", AgentLabel/binary, $., AccountLabel/binary, $., Audience/binary>>).

subscriber_id_t() ->
    ?LET(
        {MountPoint, ClientId},
        {string(), client_id_t()},
        {MountPoint, ClientId}).

binary_utf8_t() ->
    ?LET(Val, string(), unicode:characters_to_binary(Val, utf8, utf8)).

%% Exclude:
%% - multi-level wildcard '#' = <<35>>
%% - single-level wildcard '+' = <<43>>
%% - single-level separator '/' = <<47>>
%% - symbols: '.' = <<46>>
label_t() ->
    ?LET(
        Val,
        non_empty(list(union([
            integer(0, 34),
            integer(36, 42),
            integer(44, 45),
            integer(48, 16#10ffff)
        ]))),
        unicode:characters_to_binary(Val, utf8, utf8)).

%% Exclude:
%% - multi-level wildcard '#' = <<35>>
%% - single-level wildcard '+' = <<43>>
%% - single-level separator '/' = <<47>>
publish_topic_t() ->
    ?LET(
        Val,
        list(union([
            integer(0, 34),
            integer(36, 42),
            integer(44, 46),
            integer(48, 16#10ffff)
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
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            ExpectedProperties =
                #{<<"agent_label">> => AgentLabel,
                  <<"account_label">> => AccountLabel,
                  <<"audience">> => Audience,
                  <<"type">> => <<"event">>},
            ExpectedMessage = jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
            InputMessage =
                case Mode of
                    default      -> jsx:encode(#{payload => Payload});
                    payload_only -> Payload
                end,

            {ok, Modifiers} =
                auth_on_publish(Username, SubscriberId, QoS, Topic, InputMessage, IsRetain),
            {_, OutputMessage} = lists:keyfind(payload, 1, Modifiers),
            OutputMessage =:= ExpectedMessage
        end).

prop_ondeliver() ->
    ?FORALL(
        {Username, SubscriberId, Topic, Payload},
        {binary_utf8_t(), subscriber_id_t(),
         publish_topic_t(), binary_utf8_t()},
        begin
            #client_id{
                mode=Mode,
                agent_label=AgentLabel,
                account_label=AccountLabel,
                audience=Audience} = parse_client_id(element(2, SubscriberId)),
            ExpectedProperties =
                #{<<"agent_label">> => AgentLabel,
                  <<"account_label">> => AccountLabel,
                  <<"audience">> => Audience},
            InputMessage = jsx:encode(#{payload => Payload, properties => ExpectedProperties}),
            ExpectedMessage =
                case Mode of
                    default      -> InputMessage;
                    payload_only -> Payload
                end,

            {ok, Modifiers} =
                on_deliver(Username, SubscriberId, Topic, InputMessage),
            {_, OutputMessage} = lists:keyfind(payload, 1, Modifiers),
            OutputMessage =:= ExpectedMessage
        end).

prop_onsubscribe() ->
    ?FORALL(
        {Username, SubscriberId, Topics},
        {binary_utf8_t(), subscriber_id_t(), list({subscribe_topic_t(), qos_t()})},
        ok =:= auth_on_subscribe(Username, SubscriberId, Topics)).

-endif.
