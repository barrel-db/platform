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

-module(barrel_http_rest_dbs).
-author("Bernard Notarianni").

-export([init/2]).

-record(state, {method, body}).

init(Req, _Opts) ->
  barrel_monitor_activity:start(barrel_http_lib:backend_info(Req, dbs)),
  Method = cowboy_req:method(Req),
  route(Req, #state{method=Method}).


route(Req, #state{method= <<"GET">>}=State) ->
  barrel_monitor_activity:update(#{ state => active, query => list_dbs }),
  get_resource(Req, State);
route(Req, #state{method= <<"POST">>}=State) ->
  barrel_monitor_activity:update(#{ state => active, query => create_db }),
  {ok, Body, Req2} = cowboy_req:read_body(Req),
  check_body(Req2, State#state{body=Body});
route(Req, State) ->
  barrel_http_reply:error(405, Req, State).


get_resource(Req, State) ->
  Dbs = barrel:database_names(),
  barrel_http_reply:doc(Dbs, Req, State).


check_body(Req, #state{body= <<>>}=S) ->
  barrel_http_reply:error(400, <<"empty body">>, Req, S);
check_body(Req, #state{body=Body}=S) ->
  try jsx:decode(Body, [return_maps]) of
      Json ->
      create_resource(Req, S#state{body=Json})
  catch
    _:_ ->
      barrel_http_reply:error(400, <<"malformed json document for database config">>, Req, S)
  end.

create_resource(Req, #state{body=Json}=State) ->
  case barrel:create_database(Json) of
    {ok, Config} ->
      barrel_http_reply:json(201, Config, Req, State);
    {error, db_exists} ->
      barrel_http_reply:error(409, "db exists", Req, State);
    Error ->
      _ = lager:error("got server error ~p~n", [Error]),
      barrel_http_reply:error(500, "db error", Req, State)
  end.



