-module(mqttgw_http_subscription).

-export([init/2]).

-define(PAYLOAD_MAX_LEN, 10000).
-define(PAYLOAD_MAX_READTIME, 5000).

init(Req0, AuthnConfig) ->
    process(Req0, AuthnConfig).

process(Req0, State) ->
    {Status, JsonBody, Req1} = do_process(Req0, State),
    Response = cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, jsx:encode(JsonBody), Req1),
    error_logger:info_msg("HTTP api request /api/v1/subscriptions, status = ~p", [Status]),
    {ok, Response, State}.

do_process(Req0=#{method := <<"POST">>}, AuthnConfig) ->
    Response = case cowboy_req:read_body(Req0, #{length => ?PAYLOAD_MAX_LEN, period => ?PAYLOAD_MAX_READTIME}) of
        {ok, Data, Req1} ->
            try jsx:decode(Data, [return_maps]) of
                Payload ->
                    AuthorizationHeader = cowboy_req:header(<<"authorization">>, Req1),
                    case handle(AuthorizationHeader, Payload, AuthnConfig) of
                        ok ->
                            {200, #{ result => <<"success">> }, Req1};
                        {error, #{reason_code := Reason} = ErrResp} ->
                            Status = case maps:find(http_status, ErrResp) of
                                {ok, S} -> S;
                                _ -> 422
                            end,
                            {Status, #{error => Reason}, Req1}
                    end
            catch
                T:R ->
                    error_logger:error_msg(
                        "Failed to parse json, payload = ~p"
                        "exception_type = ~p, exception_reason = ~p",
                        [Data, T, R]),
                    {422, #{error => <<"failed to parse json payload">>}, Req1}
            end;
        _ ->
            {413, #{error => <<"payload too large">>}, Req0}
    end,
    Response;
do_process(Req0, _State) ->
    {405, #{error => <<"invalid method">>}, Req0}.

handle(AuthorizationHeader, #{<<"object">> := Object, <<"subject">> := Subject, <<"version">> := Version }, AuthnConfig) ->
    case check_authz(AuthorizationHeader, AuthnConfig) of
        {ok, AccountId} ->
            try
                App = mqttgw_authn:format_account_id(AccountId),
                Data = #{app => App, object => Object, version => Version},
                {Topic, QoS} = mqttgw_dyn_srv:authz_subscription_topic(Data),
                {BroadcastTopic, BroadcastQoS} = mqttgw_dyn_srv:authz_broadcast_subscription_topic(Data),
                mqttgw_broker:subscribe(Subject, [{Topic, QoS}, {BroadcastTopic, BroadcastQoS}]),
                error_logger:info_msg(
                    "Dynamic subscription: ~p has been created "
                    "for the subject = '~s'",
                    [Topic, Subject]
                ),
                ok
            catch
                T:R ->
                    error_logger:error_msg(
                    "Internal server error, exception_type = ~p, exception_reason = ~p",
                    [T, R]),
                {error, #{reason_code => internal_server_error, http_status => 500}}
            end;
        Err -> Err
    end;
handle(_, _, _) ->
    {error, #{reason_code => invalid_payload}}.

check_authz(<<"Bearer ",Token/binary>>, {enabled, AuthnCfg}) ->
    try mqttgw_authn:authenticate(Token, AuthnCfg) of
        AccountId ->
            error_logger:warning_msg("Auth check, token = '~p', ~p", [AccountId, maps:find(label, AccountId)]),
            case maps:find(label, AccountId) of
                {ok, <<"conference">>} -> {ok, AccountId};
                {ok, <<"event">>} -> {ok, AccountId};
                _ -> {error, #{reason_code => not_allowed}}
            end
    catch
        T:R ->
            error_logger:warning_msg(
                "Auth check error, token = '~s'"
                "exception_type = ~p, exception_reason = ~p",
                [Token, T, R]),
            {error, #{reason_code => bad_username_or_password, http_status => 401}}
    end;
check_authz(_WrongAuthzHeader, {enabled, _AuthnCfg}) ->
    {error, #{reason_code => invalid_authorization_header, http_status => 401}};
check_authz(_AuthzHeader, _DisabledAuthn) ->
    {error, #{reason_code => authn_disabled, http_status => 401}}.
