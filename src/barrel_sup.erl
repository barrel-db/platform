%%%-------------------------------------------------------------------
%% @doc barrel_core top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module('barrel_sup').

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  case supervisor:start_link({local, ?SERVER}, ?MODULE, []) of
    {ok, Pid} ->
      io:format("version: ~s.", [barrel_server:version()]),
      io:format("node id: ~s", [barrel_server:node_id()]),
      couch_httpd_util:display_uris(),
      {ok, Pid};
    Else ->
      Else
  end.



%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->

  UUIDs = {barrel_uuids,
           {barrel_uuids, start_link, []},
           permanent, brutal_kill, worker, [barrel_uuids]},

  %% safe supervisor, like kernel_safe_sup but for barrel, allows to register
  %% external applications to it like stores if needed.
  ExtSup = {barrel_ext_sup,
            {barrel_ext_sup, start_link, []},
            permanent, infinity, supervisor, [barrel_ext_sup]},

  Server = {barrel_server,
            {barrel_server, start_link, []},
            permanent,brutal_kill,	worker,[barrel_server]},


  Daemons = {barrel_daemons_sup,
             {barrel_daemons_sup, start_link, []},
             permanent, infinity, supervisor, [barrel_daemons_sup]},

  Http = {couch_httpd_sup,
          {couch_httpd_sup, start_link, []},
          permanent, infinity, supervisor, [couch_httpd_sup]},

  Index = {couch_index_sup,
           {couch_index_sup, start_link, []},
           permanent, infinity, supervisor, [couch_index_sup]},

  Replicator = {couch_replicator_sup,
                {couch_replicator_sup, start_link, []},
                permanent, infinity, supervisor, [couch_replicator_sup]},

  Metrics = {barrel_metrics_sup,
             {barrel_metrics_sup, start_link, []},
             permanent, infinity, supervisor, [barrel_metrics_sup]},

  Api = {barrel_api_sup,
         {barrel_api_sup, start_link, []},
         permanent, infinity, supervisor, [barrel_api_sup]},

  {ok, { {one_for_all, 0, 10}, [UUIDs, ExtSup, Metrics, Server, Daemons,
                                Http, Api, Index, Replicator]} }.

%%====================================================================
%% Internal functions
%%====================================================================
