%% Copyright (c) 2016, Benoit Chesneau
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
%%

-module(barrel_legacy_handler).
-author("Benoit Chesneau").

%% API
-export([init/3, loop/1]).
-export([options/0]).


init(_, _, _) ->  {upgrade, protocol, mochicow_upgrade}.

loop(Req) ->
  Opts = Req:get(opts),
  DefaultFun = proplists:get_value(default_fun, Opts),
  UrlHandlers = proplists:get_value(url_handlers, Opts),
  DbUrlHandlers = proplists:get_value(db_url_handlers, Opts),
  DesignUrlHandlers = proplists:get_value(design_url_handlers, Opts),

  H = mochiweb_request:get_header_value("Upgrade", Req),
  IsWebsocket = (H =/= undefined andalso string:to_lower(H) =:= "websocket"),
  {ok, SocketOptions} = couch_util:parse_term(barrel_config:get("httpd", "socket_options", "[]")),

  case SocketOptions of
    [] -> ok;
    _ ->  ok = mochiweb_socket:setopts(Req:get(socket), SocketOptions)
  end,

  case IsWebsocket of
    false -> couch_httpd:handle_request(Req, DefaultFun, UrlHandlers, DbUrlHandlers, DesignUrlHandlers);
    true ->
      {ReentryWs, _ReplyChannel} = mochiweb_websocket:upgrade_connection(Req,
        fun barrel_websocket:ws_loop/3),
      ReentryWs([])
  end.

options() ->
  DefaultSpec = "{couch_httpd_db, handle_request}",
  DefaultFun = couch_httpd:make_arity_1_fun(
    barrel_config:get("httpd", "default_handler", DefaultSpec)
  ),

  UrlHandlersList = lists:map(
    fun({UrlKey, SpecStr}) ->
      {list_to_binary(UrlKey), couch_httpd:make_arity_1_fun(SpecStr)}
    end, barrel_config:get("httpd_global_handlers")),

  DbUrlHandlersList = lists:map(
    fun({UrlKey, SpecStr}) ->
      {list_to_binary(UrlKey), couch_httpd:make_arity_2_fun(SpecStr)}
    end, barrel_config:get("httpd_db_handlers")),

  DesignUrlHandlersList = lists:map(
    fun({UrlKey, SpecStr}) ->
      {list_to_binary(UrlKey), couch_httpd:make_arity_3_fun(SpecStr)}
    end, barrel_config:get("httpd_design_handlers")),

  UrlHandlers = dict:from_list(UrlHandlersList),
  DbUrlHandlers = dict:from_list(DbUrlHandlersList),
  DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),

  set_auth_handlers(),

  % add barrel log event handler
  lager_handler_watcher:start(lager_event, barrel_log_event_handler, []),

  [{url_handlers, UrlHandlers}, {db_url_handlers, DbUrlHandlers},
    {design_url_handlers, DesignUrlHandlers}, {default_fun, DefaultFun},
    {loop, {?MODULE, loop}}].


set_auth_handlers() ->
  AuthenticationSrcs = couch_httpd:make_fun_spec_strs(
    barrel_config:get("httpd", "authentication_handlers", "")),
  AuthHandlers = lists:map(
    fun(A) -> {couch_httpd:make_arity_1_fun(A), list_to_binary(A)} end, AuthenticationSrcs),
  ok = application:set_env(couch_httpd, auth_handlers, AuthHandlers).