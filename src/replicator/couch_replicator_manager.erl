%% Copyright 2016, Benoit Chesneau
%% Copyright 2009-2014 The Apache Software Foundation
%%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_replicator_manager).
-behaviour(gen_server).

% public API
-export([replication_started/1, replication_completed/2, replication_error/2]).

-export([before_doc_update/2, after_doc_read/2]).

% gen_server callbacks
-export([start_link/0, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).


%% internal
-export([listen_db_changes/1]).

-include_lib("couch_db.hrl").
-include("couch_replicator.hrl").
-include("couch_replicator_js_functions.hrl").


-define(DOC_TO_REP, couch_rep_doc_id_to_rep_id).
-define(REP_TO_STATE, couch_rep_id_to_rep_state).
-define(INITIAL_WAIT, 2.5). % seconds
-define(MAX_WAIT, 600).     % seconds
-define(OWNER, <<"owner">>).

-record(rep_state, {
    rep,
    starting,
    retries_left,
    max_retries,
    wait = ?INITIAL_WAIT
}).

-record(state, {
    changes_feed_loop = nil,
    db_notifier = nil,
    rep_db_name = nil,
    rep_start_pids = [],
    max_retries,
    listener
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


replication_started(#rep{id = {BaseId, _} = RepId}) ->
    case rep_state(RepId) of
    nil ->
        ok;
    #rep_state{rep = #rep{doc_id = DocId}} ->
        update_rep_doc(DocId, #{<<"_replication_state">> => <<"triggered">>,
                                <<"_replication_state_reason">> => undefined,
                                <<"_replication_id">> => list_to_binary(BaseId),
                                <<"_replication_stats">> => undefined}),
        ok = gen_server:call(?MODULE, {rep_started, RepId}, infinity),
        lager:info("Document `~s` triggered replication `~s`",
            [DocId, pp_rep_id(RepId)])
    end.


replication_completed(#rep{id = RepId}, Stats) ->
  case rep_state(RepId) of
    nil ->
      ok;
    #rep_state{rep = #rep{doc_id = DocId}} ->
      update_rep_doc(DocId, #{<<"_replication_state">> => <<"completed">>,
                              <<"_replication_state_reason">> => undefined,
                              <<"_replication_stats">> => Stats}),
      ok = gen_server:call(?MODULE, {rep_complete, RepId}, infinity),
      lager:info("Replication `~s` finished (triggered by document `~s`)",
                 [pp_rep_id(RepId), DocId])
  end.


replication_error(#rep{id = {BaseId, _} = RepId}, Error) ->
  case rep_state(RepId) of
    nil ->
      ok;
    #rep_state{rep = #rep{doc_id = DocId}} ->
      update_rep_doc(DocId, #{<<"_replication_state">> => <<"error">>,
                              <<"_replication_state_reason">> => barrel_lib:to_error(error_reason(Error)),
                              <<"_replication_id">> => list_to_binary(BaseId)}),
      ok = gen_server:call(?MODULE, {rep_error, RepId, Error}, infinity)
  end.





init(_) ->
    process_flag(trap_exit, true),
    ?DOC_TO_REP = ets:new(?DOC_TO_REP, [named_table, set, protected]),
    ?REP_TO_STATE = ets:new(?REP_TO_STATE, [named_table, set, protected]),

    {Loop, RepDbName} = changes_feed_loop(),

    Listener = start_listener(self()),

    Retries = retries_value(barrel_server:get_env(max_replication_retry_count)),
    {ok, #state{changes_feed_loop = Loop,
                rep_db_name = RepDbName,
                max_retries = Retries,
                listener=Listener}}.


handle_call({rep_db_update, Change}, _From, State) ->
    NewState = try
        process_update(State, Change)
    catch
    _Tag:Error ->
        RepProps = maps:get(doc, Change),
        DocId = maps:get(<<"_id">>, RepProps),
        rep_db_update_error(Error, DocId),
        State
    end,
    {reply, ok, NewState};


handle_call({rep_started, RepId}, _From, State) ->
    case rep_state(RepId) of
    nil ->
        ok;
    RepState ->
        NewRepState = RepState#rep_state{
            starting = false,
            retries_left = State#state.max_retries,
            max_retries = State#state.max_retries,
            wait = ?INITIAL_WAIT
        },
        true = ets:insert(?REP_TO_STATE, {RepId, NewRepState})
    end,
    {reply, ok, State};

handle_call({rep_complete, RepId}, _From, State) ->
    true = ets:delete(?REP_TO_STATE, RepId),
    {reply, ok, State};

handle_call({rep_error, RepId, Error}, _From, State) ->
    {reply, ok, replication_error(State, RepId, Error)};

handle_call(Msg, From, State) ->
    lager:error("Replication manager received unexpected call ~p from ~p",
        [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.


handle_cast({rep_db_changed, NewName}, #state{rep_db_name = NewName} = State) ->
    {noreply, State};

handle_cast({rep_db_changed, _NewName}, State) ->
    {noreply, restart(State)};

handle_cast({rep_db_created, NewName}, #state{rep_db_name = NewName} = State) ->
    {noreply, State};

handle_cast({rep_db_created, _NewName}, State) ->
    {noreply, restart(State)};

handle_cast({set_max_retries, MaxRetries}, State) ->
    {noreply, State#state{max_retries = MaxRetries}};

handle_cast(Msg, State) ->
    lager:error("Replication manager received unexpected cast ~p", [Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.

handle_info({'$barrel_event', DbName, created}, State) ->
    case DbName of
        <<"_replicator">> ->
            {noreply, restart(State)};
        _ ->
            {noreply, State}
    end;
handle_info({'EXIT', From, _}, #state{listener = From} = State) ->
    {noreply, State#state{listener = start_listener(self())}};

handle_info({'EXIT', From, normal}, #state{changes_feed_loop = From} = State) ->
    % replicator DB deleted
    {noreply, State#state{changes_feed_loop = nil, rep_db_name = nil}};

handle_info({'EXIT', From, normal}, #state{rep_start_pids = Pids} = State) ->
    % one of the replication start processes terminated successfully
    {noreply, State#state{rep_start_pids = Pids -- [From]}};

handle_info({'DOWN', _Ref, _, _, _}, State) ->
    % From a db monitor created by a replication process. Ignore.
    {noreply, State};
handle_info(Msg, State) ->
    lager:error("Replication manager received unexpected message ~p", [Msg]),
    {stop, {unexpected_msg, Msg}, State}.


terminate(_Reason, State) ->
    #state{
        rep_start_pids = StartPids,
        changes_feed_loop = Loop,
        listener = Listener
    } = State,
    catch barrel_event:unreg(),

    stop_all_replications(),
    lists:foreach(
        fun(Pid) ->
            catch unlink(Pid),
            catch exit(Pid, stop)
        end,
        [Loop, Listener | StartPids]),
    true = ets:delete(?REP_TO_STATE),
    true = ets:delete(?DOC_TO_REP),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


start_listener(Parent) ->
    spawn_link(?MODULE, listen_db_changes, [Parent]).

listen_db_changes(Parent) ->
    barrel_event:reg_all(),
    db_changes_loop(Parent).

db_changes_loop(Parent) ->
    receive
        {'barrel_event', _DbName, created}=Event ->
            Parent ! Event,
            db_changes_loop(Parent);
        _ ->
            db_changes_loop(Parent)
    end.


changes_feed_loop() ->
    {ok, RepDb} = ensure_rep_db_exists(),
    RepDbName = couch_db:name(RepDb),
    couch_db:close(RepDb),
    Server = self(),
    Pid = spawn_link(
        fun() ->
            DbOpenOptions = [{user_ctx, RepDb#db.user_ctx}, sys_db],
            {ok, Db} = couch_db:open_int(RepDbName, DbOpenOptions),
            ChangesFeedFun = couch_changes:handle_changes(
                #changes_args{
                    include_docs = true,
                    feed = "continuous",
                    timeout = infinity
                },
                {json_req, null},
                Db
            ),
            ChangesFeedFun(
                fun({change, Change, _}, _) ->
                    case has_valid_rep_id(Change) of
                    true ->
                        ok = gen_server:call(
                            Server, {rep_db_update, Change}, infinity);
                    false ->
                        ok
                    end;
                (_, _) ->
                    ok
                end
            )
        end
    ),
    {Pid, RepDbName}.


has_valid_rep_id(Change) when is_map(Change) ->
    has_valid_rep_id(maps:get(<<"id">>, Change));
has_valid_rep_id(<<?DESIGN_DOC_PREFIX, _Rest/binary>>) ->
    false;
has_valid_rep_id(_Else) ->
    true.

restart(#state{changes_feed_loop = Loop, rep_start_pids = StartPids} = State) ->
    stop_all_replications(),
    lists:foreach(
        fun(Pid) ->
            catch unlink(Pid),
            catch exit(Pid, rep_db_changed)
        end,
        [Loop | StartPids]),
    {NewLoop, NewRepDbName} = changes_feed_loop(),
    State#state{
        changes_feed_loop = NewLoop,
        rep_db_name = NewRepDbName,
        rep_start_pids = []
    }.


process_update(State, Change) ->
    RepDoc = maps:get(doc, Change),
    DocId = maps:get(<<"_id">>, RepDoc),
    case maps:get(<<"deleted">>, Change, false) of
    true ->
        rep_doc_deleted(DocId),
        State;
    false ->
        case maps:get(<<"_replication_state">>, RepDoc, undefined) of
        undefined ->
            maybe_start_replication(State, DocId, RepDoc);
        <<"triggered">> ->
            maybe_start_replication(State, DocId, RepDoc);
        <<"completed">> ->
            replication_complete(DocId),
            State;
        <<"error">> ->
            case ets:lookup(?DOC_TO_REP, DocId) of
            [] ->
                maybe_start_replication(State, DocId, RepDoc);
            _ ->
                State
            end
        end
    end.


rep_db_update_error(Error, DocId) ->
  Reason = case Error of
             {bad_rep_doc, R} -> R;
             _ -> barrel_lib:to_error(Error)
           end,
  lager:error("Replication manager, error processing document `~s`: ~s",
              [DocId, Reason]),
  update_rep_doc(DocId, #{<<"_replication_state">> => <<"error">>,
                          <<"_replication_state_reason">> => Reason}).


rep_user_ctx(RepDoc) ->
  case maps:get(<<"user_ctx">>, RepDoc, undefined) of
    undefined -> barrel_lib:userctx();
    UserCtx ->
        Name = maps:get(<<"name">>, UserCtx, null),
        Roles = maps:get(<<"roles">>, UserCtx, []),
        barrel_lib:userctx([{name, Name}, {roles, Roles}])
    end.


maybe_start_replication(State, DocId, RepDoc) ->
    #rep{id = {BaseId, _} = RepId} = Rep = parse_rep_doc(RepDoc),
    case rep_state(RepId) of
    nil ->
        RepState = #rep_state{
            rep = Rep,
            starting = true,
            retries_left = State#state.max_retries,
            max_retries = State#state.max_retries
        },
        true = ets:insert(?REP_TO_STATE, {RepId, RepState}),
        true = ets:insert(?DOC_TO_REP, {DocId, RepId}),
        lager:info("Attempting to start replication `~s` (document `~s`).",
            [pp_rep_id(RepId), DocId]),
        Pid = spawn_link(fun() -> start_replication(Rep, 0) end),
        State#state{rep_start_pids = [Pid | State#state.rep_start_pids]};
    #rep_state{rep = #rep{doc_id = DocId}} ->
        State;
    #rep_state{starting = false, rep = #rep{doc_id = OtherDocId}} ->
        lager:info("The replication specified by the document `~s` was already"
            " triggered by the document `~s`", [DocId, OtherDocId]),
        maybe_tag_rep_doc(DocId, RepDoc, list_to_binary(BaseId)),
        State;
    #rep_state{starting = true, rep = #rep{doc_id = OtherDocId}} ->
        lager:info("The replication specified by the document `~s` is already"
            " being triggered by the document `~s`", [DocId, OtherDocId]),
        maybe_tag_rep_doc(DocId, RepDoc, list_to_binary(BaseId)),
        State
    end.


parse_rep_doc(RepDoc) ->
    {ok, Rep} = try
        couch_replicator_utils:parse_rep_doc(RepDoc, rep_user_ctx(RepDoc))
    catch
    throw:{error, Reason} ->
        throw({bad_rep_doc, Reason});
    Tag:Err ->
        throw({bad_rep_doc, barrel_lib:to_error({Tag, Err})})
    end,
    Rep.


maybe_tag_rep_doc(DocId, RepProps, RepId) ->
    case maps:get(<<"_replication_id">>, RepProps, undefined) of
    RepId ->
        ok;
    _ ->
        update_rep_doc(DocId, [{<<"_replication_id">>, RepId}])
    end.


start_replication(Rep, Wait) ->
    ok = timer:sleep(Wait * 1000),
    case (catch couch_replicator:async_replicate(Rep)) of
    {ok, _} ->
        ok;
    Error ->
        replication_error(Rep, Error)
    end.


replication_complete(DocId) ->
    case ets:lookup(?DOC_TO_REP, DocId) of
    [{DocId, {BaseId, Ext} = RepId}] ->
        case rep_state(RepId) of
        nil ->
            % Prior to OTP R14B02, temporary child specs remain in
            % in the supervisor after a worker finishes - remove them.
            % We want to be able to start the same replication but with
            % eventually different values for parameters that don't
            % contribute to its ID calculation.
            case erlang:system_info(otp_release) < "R14B02" of
            true ->
                spawn(fun() ->
                    _ = supervisor:delete_child(couch_replicator_job_sup, BaseId ++ Ext)
                end);
            false ->
                ok
            end;
        #rep_state{} ->
            ok
        end,
        true = ets:delete(?DOC_TO_REP, DocId);
    _ ->
        ok
    end.


rep_doc_deleted(DocId) ->
    case ets:lookup(?DOC_TO_REP, DocId) of
    [{DocId, RepId}] ->
        couch_replicator:cancel_replication(RepId),
        true = ets:delete(?REP_TO_STATE, RepId),
        true = ets:delete(?DOC_TO_REP, DocId),
        lager:info("Stopped replication `~s` because replication document `~s`"
            " was deleted", [pp_rep_id(RepId), DocId]);
    [] ->
        ok
    end.


replication_error(State, RepId, Error) ->
    case rep_state(RepId) of
    nil ->
        State;
    RepState ->
        maybe_retry_replication(RepState, Error, State)
    end.

maybe_retry_replication(#rep_state{retries_left = 0} = RepState, Error, State) ->
    #rep_state{
        rep = #rep{id = RepId, doc_id = DocId},
        max_retries = MaxRetries
    } = RepState,
    couch_replicator:cancel_replication(RepId),
    true = ets:delete(?REP_TO_STATE, RepId),
    true = ets:delete(?DOC_TO_REP, DocId),
    lager:error("Error in replication `~s` (triggered by document `~s`): ~s"
        "~nReached maximum retry attempts (~p).",
        [pp_rep_id(RepId), DocId, barrel_lib:to_error(error_reason(Error)), MaxRetries]),
    State;

maybe_retry_replication(RepState, Error, State) ->
    #rep_state{
        rep = #rep{id = RepId, doc_id = DocId} = Rep
    } = RepState,
    #rep_state{wait = Wait} = NewRepState = state_after_error(RepState),
    true = ets:insert(?REP_TO_STATE, {RepId, NewRepState}),
    lager:error("Error in replication `~s` (triggered by document `~s`): ~s"
        "~nRestarting replication in ~p seconds.",
        [pp_rep_id(RepId), DocId, barrel_lib:to_error(error_reason(Error)), Wait]),
    Pid = spawn_link(fun() -> start_replication(Rep, Wait) end),
    State#state{rep_start_pids = [Pid | State#state.rep_start_pids]}.


stop_all_replications() ->
    lager:info("Stopping all ongoing replications because the replicator"
        " database was deleted or changed", []),
    ets:foldl(
        fun({_, RepId}, _) ->
            couch_replicator:cancel_replication(RepId)
        end,
        ok, ?DOC_TO_REP),
    true = ets:delete_all_objects(?REP_TO_STATE),
    true = ets:delete_all_objects(?DOC_TO_REP).


update_rep_doc(RepDocId, KVs) ->
    {ok, RepDb} = ensure_rep_db_exists(),
    try
        case couch_db:open_doc(RepDb, RepDocId, [ejson_body]) of
        {ok, LatestRepDoc} ->
            update_rep_doc(RepDb, LatestRepDoc, KVs);
        _ ->
            ok
        end
    catch throw:conflict ->
        % Shouldn't happen, as by default only the role _replicator can
        % update replication documents.
        lager:error("Conflict error when updating replication document `~s`."
            " Retrying.", [RepDocId]),
        ok = timer:sleep(5),
        update_rep_doc(RepDocId, KVs)
    after
        couch_db:close(RepDb)
    end.

update_rep_doc(RepDb, #doc{body = RepDocBody} = RepDoc, KVs) ->
  NewRepDocBody = maps:fold(fun
                              (K, undefined, Body) ->
                                maps:remove(K, Body);
                              (<<"_replication_state">> = K, State, Body) ->
                                case maps:find(K, Body) of
                                  {ok, State} -> Body;
                                  _ ->
                                    Body#{K => State,
                                          <<"_replication_state_time">> => timestamp()}
                                end;
                              (K, V, Body) ->
                                Body#{ K => V }
                            end, RepDocBody, KVs),
  case NewRepDocBody of
    RepDocBody ->
      ok;
    _ ->
      % Might not succeed - when the replication doc is deleted right
      % before this update (not an error, ignore).
      couch_db:update_doc(RepDb, RepDoc#doc{body = NewRepDocBody}, [])
  end.


% RFC3339 timestamps.
% Note: doesn't include the time seconds fraction (RFC3339 says it's optional).
timestamp() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:now_to_local_time(os:timestamp()),
    UTime = erlang:universaltime(),
    LocalTime = calendar:universal_time_to_local_time(UTime),
    DiffSecs = calendar:datetime_to_gregorian_seconds(LocalTime) -
        calendar:datetime_to_gregorian_seconds(UTime),
    zone(DiffSecs div 3600, (DiffSecs rem 3600) div 60),
    iolist_to_binary(
        io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w~s",
            [Year, Month, Day, Hour, Min, Sec,
                zone(DiffSecs div 3600, (DiffSecs rem 3600) div 60)])).

zone(Hr, Min) when Hr >= 0, Min >= 0 ->
    io_lib:format("+~2..0w:~2..0w", [Hr, Min]);
zone(Hr, Min) ->
    io_lib:format("-~2..0w:~2..0w", [abs(Hr), abs(Min)]).



ensure_rep_db_exists() ->
    Roles = [<<"_admin">>, <<"_replicator">>],
    UserCtx = barrel_lib:userctx([{roles, Roles}]),
    case couch_db:open_int( <<"_replicator">>, [sys_db, {user_ctx, UserCtx}, nologifmissing]) of
    {ok, Db} ->
        Db;
    _Error ->
        {ok, Db} = couch_db:create( <<"_replicator">>, [sys_db, {user_ctx, UserCtx}])
    end,
    ensure_rep_ddoc_exists(Db, <<"_design/_replicator">>),
    {ok, Db}.


ensure_rep_ddoc_exists(RepDb, DDocID) ->
    case couch_db:open_doc(RepDb, DDocID, []) of
    {ok, _Doc} ->
        ok;
    _ ->
        DDoc = barrel_doc:from_json_obj(#{<<"_id">> => DDocID,
                                         <<"language">> => <<"javascript">>,
                                         <<"validate_doc_update">> => ?REP_DB_DOC_VALIDATE_FUN
                                        }),
        {ok, _Rev} = couch_db:update_doc(RepDb, DDoc, [])
     end.


% pretty-print replication id
pp_rep_id(#rep{id = RepId}) ->
    pp_rep_id(RepId);
pp_rep_id({Base, Extension}) ->
    << Base/binary, Extension/binary>>.


rep_state(RepId) ->
    case ets:lookup(?REP_TO_STATE, RepId) of
    [{RepId, RepState}] ->
        RepState;
    [] ->
        nil
    end.


error_reason({error, {Error, Reason}})
  when is_atom(Error), is_binary(Reason) ->
    io_lib:format("~s: ~s", [Error, Reason]);
error_reason({error, Reason}) ->
    Reason;
error_reason(Reason) ->
    Reason.


retries_value("infinity") ->  infinity;
retries_value(Value) -> Value.


state_after_error(#rep_state{retries_left = Left, wait = Wait} = State) ->
    Wait2 = erlang:min(trunc(Wait * 2), ?MAX_WAIT),
    case Left of
    infinity ->
        State#rep_state{wait = Wait2};
    _ ->
        State#rep_state{retries_left = Left - 1, wait = Wait2}
    end.


before_doc_update(#doc{id = <<?DESIGN_DOC_PREFIX, _/binary>>} = Doc, _Db) ->
    Doc;
before_doc_update(#doc{body = Body} = Doc, #db{user_ctx=UserCtx} = Db) ->
    [Name, Roles] = barrel_lib:userctx_get([name, roles], UserCtx),
    case lists:member(<<"_replicator">>, Roles) of
    true ->
        Doc;
    false ->
        case maps:get(?OWNER, Body, undefined) of
        undefined ->
            Doc#doc{body = maps:put(?OWNER, Name, Body)};
        Name ->
            Doc;
        Other ->
            case (catch couch_db:check_is_admin(Db)) of
            ok when Other =:= null ->
                Doc#doc{body = maps:put(?OWNER, Name, Body)};
            ok ->
                Doc;
            _ ->
                throw({forbidden, <<"Can't update replication documents",
                    " from other users.">>})
            end
        end
    end.


after_doc_read(#doc{id = <<?DESIGN_DOC_PREFIX, _/binary>>} = Doc, _Db) ->
    Doc;
after_doc_read(#doc{body = Body} = Doc, #db{user_ctx=UserCtx} = Db) ->
    Name = barrel_lib:userctx_get(name, UserCtx),
    case (catch couch_db:check_is_admin(Db)) of
    ok ->
        Doc;
    _ ->
        case maps:get(?OWNER, Body, undefined) of
        Name ->
            Doc;
        _Other ->
            Source = strip_credentials(maps:get(<<"source">>, Body, undefined)),
            Target = strip_credentials(maps:get(<<"target">>, Body, undefined)),
            NewBody0 = maps:put(<<"source">>, Source, Body),
            NewBody = maps:put(<<"target">>, Target, NewBody0),
            #doc{revs = {Pos, [_ | Revs]}} = Doc,
            NewDoc = Doc#doc{body = NewBody, revs = {Pos - 1, Revs}},
            NewRevId = couch_db:new_revid(NewDoc),
            NewDoc#doc{revs = {Pos, [NewRevId | Revs]}}
        end
    end.


strip_credentials(undefined) ->
    undefined;
strip_credentials(Url) when is_binary(Url) ->
    re:replace(Url,
        "http(s)?://(?:[^:]+):[^@]+@(.*)$",
        "http\\1://\\2",
        [{return, binary}]);
strip_credentials(Props) ->
    maps:remove(<<"oauth">>,Props).
