%% ----------------------------------------------------------------------------
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
%% ----------------------------------------------------------------------------

-module(mqttgw).

-behaviour(auth_on_register_hook).
-behaviour(auth_on_subscribe_hook).
-behaviour(auth_on_publish_hook).

%% Plugin callbacks
-export([
    auth_on_register/5,
    auth_on_publish/6,
    auth_on_subscribe/3
]).

%% =============================================================================
%% Plugin Callbacks
%% =============================================================================

auth_on_register(
    {_IpAddr, _Port} = Peer, {_MountPoint, _ClientId} = SubscriberId, UserName,
    Password, CleanSession) ->

    error_logger:info_msg(
        "auth_on_register: ~p ~p ~p ~p ~p",
        [Peer, SubscriberId, UserName, Password, CleanSession]),
    ok.

auth_on_publish(
    UserName, {_MountPoint, _ClientId} = SubscriberId,
    QoS, Topic, Payload, IsRetain) ->

    error_logger:info_msg(
        "auth_on_publish: ~p ~p ~p ~p ~p ~p",
        [UserName, SubscriberId, QoS, Topic, Payload, IsRetain]),
    ok.

auth_on_subscribe(
    UserName, ClientId,
    [{_Topic, _QoS}|_] = Topics) ->

    error_logger:info_msg(
        "auth_on_subscribe: ~p ~p ~p",
        [UserName, ClientId, Topics]),
    ok.
