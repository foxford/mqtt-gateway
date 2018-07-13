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

-module(mqttgw_state).

%% API
-export([
    new/0,
    get/1,
    put/2
]).

%% Types
-record(state, {
    key,
    value
}).

%% Definitions
-define(STATE_TABLE, ?MODULE).

%% =============================================================================
%% API
%% =============================================================================

-spec new() -> ok.
new() ->
    _ = ets:new(
        ?STATE_TABLE,
        [ set, public, named_table,
          {keypos, #state.key},
          {read_concurrency, true} ]),
    ok.

-spec get(any()) -> any().
get(Key) ->
    ets:lookup_element(?STATE_TABLE, Key, #state.value).

-spec put(any(), any()) -> ok.
put(Key, Val) ->
    ets:insert(?STATE_TABLE, #state{key=Key, value=Val}),
    ok.