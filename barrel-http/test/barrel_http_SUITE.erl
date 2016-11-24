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

-module(barrel_http_SUITE).

-export([all/0,
         end_per_suite/1,
         end_per_testcase/2,
         init_per_suite/1,
         init_per_testcase/2]).

-export([info_database/1,
         create_database/1,
         system_doc/1]).

all() -> [ info_database
         , create_database
         , system_doc
         ].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(barrel_http),
  Config.

init_per_testcase(_, Config) ->
  {true, Conn} = barrel:create_database(testdb, <<"testdb">>),
  [{conn, Conn} |Config].

end_per_testcase(_, Config) ->
  Conn = proplists:get_value(conn, Config),
  ok = barrel:delete_database(Conn),
  Config.

end_per_suite(Config) ->
  catch erocksdb:destroy(<<"testdb">>), Config.

%% ----------

info_database(_Config) ->
  {200, R1} = test_lib:req(get, "/testdb/testdb"),
  A1 = jsx:decode(R1, [return_maps]),
  <<"testdb">> = maps:get(<<"name">>, A1),
  %% TODO refactor
  %% {404, _} = test_lib:req(get, "/unknwondb"),
  ok.

create_database(_Config) ->
  Cat = "{\"_id\": \"cat\", \"name\" : \"tom\"}",
  {400, _} = test_lib:req(put, "/testdb/newdb/cat", Cat),
  {201, _} = test_lib:req(put, "/testdb/newdb", []),
  {201, _} = test_lib:req(put, "/testdb/newdb/cat", Cat),
  ok.

system_doc(_Config) ->
  Doc = "{\"_id\": \"cat\", \"name\" : \"tom\"}",
  {201, _} = test_lib:req(put, "/testdb/testdb/_system/cat", Doc),
  {200, R} = test_lib:req(get, <<"/testdb/testdb/_system/cat">>),
  J = jsx:decode(R, [return_maps]),
  #{<<"name">> := <<"tom">>} = J,
  {200, _} = test_lib:req(put, "/testdb/testdb/_system/cat", "{}"),
  {204, _} = test_lib:req(delete, "/testdb/testdb/_system/cat"),
  {404, _} = test_lib:req(get, <<"/testdb/testdb/_system/cat">>),
  ok.

