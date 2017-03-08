%% Copyright 2016, Bernard Notarianni
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(barrel_stats_statsd).
-author("Bernard Notarianni").

-behaviour(barrel_stats_plugin).
-bahaviour(gen_server).

%% plugin callbacks
-export([ init/3
        , increment/2
        ]).


init(_Type, _Name, _Env) ->
  ok.

increment(Name, Env) ->
  Server = proplists:get_value(statsd_server, Env),
  push(Server, Name, {counter, 1}),
  ok.


push(_, _, undefined) ->
  ok;
push(Server, Name, Value) ->
  StasdKey = barrel_lib:binary_join(Name, <<"/">>),
  send(Server, StasdKey, Value).

send({Peer, Port}, Key, {counter, Value}) ->
  ct:print("send"),
  BVal = integer_to_binary(Value),
  Data = <<Key/binary, ":", BVal/binary, "|c">>,
  udp(Peer, Port, Data).

udp(Peer, Port, Data) ->
  Fun = fun() ->
            ct:print("udp ~p ~p ~p", [Peer, Port, Data]),
            case gen_udp:open(0) of
              {ok, Socket} ->
                ok = gen_udp:send(Socket, Peer, Port, Data),
                ct:print("ok"),
                gen_udp:close(Socket);
              Error ->
                lagger:error("can not open udp socket to statsd server: ~p", [Error])
            end
        end,
 spawn(Fun).