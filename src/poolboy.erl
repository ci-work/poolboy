%% Poolboy - A hunky Erlang worker pool factory

-module(poolboy).
-behaviour(gen_fsm).

-export([checkout/1, checkout/2, checkout/3, checkin/2,
         child_spec/2, start_link/1, stop/1]).
-export([init/1, ready/2, ready/3, overflow/2, overflow/3, full/2, full/3,
         handle_event/3, handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-define(TIMEOUT, 5000).

-record(state, {
    supervisor :: pid(),
    workers :: queue(),
    waiting :: queue(),
    monitors :: ets:tid(),
    size = 5 :: non_neg_integer(),
    overflow = 0 :: non_neg_integer(),
    max_overflow = 10 :: non_neg_integer()
}).

-spec checkout(Pool :: node()) -> pid().
checkout(Pool) ->
    checkout(Pool, true).

-spec checkout(Pool :: node(), Block :: boolean()) -> pid() | full.
checkout(Pool, Block) ->
    checkout(Pool, Block, ?TIMEOUT).

-spec checkout(Pool :: node(), Block :: boolean(), Timeout :: timeout())
    -> pid() | full.
checkout(Pool, Block, Timeout) ->
    gen_fsm:sync_send_event(Pool, {checkout, Block, Timeout}, Timeout).

-spec checkin(Pool :: node(), Worker :: pid()) -> ok.
checkin(Pool, Worker) ->
    gen_fsm:send_event(Pool, {checkin, Worker}).

-spec child_spec(Pool :: node(), Args :: proplists:proplist()) ->
    supervisor:child_spec().
child_spec(Pool, Args) ->
    {Pool, {poolboy, start_link, [Args]},
     permanent, 5000, worker, [poolboy]}.

-spec start_link(Args :: proplists:proplist()) -> {ok, pid()}.
start_link(Args) ->
    case proplists:get_value(name, Args) of
        undefined ->
            gen_fsm:start_link(?MODULE, Args, []);
        Name ->
            gen_fsm:start_link(Name, ?MODULE, Args, [])
    end.

-spec stop(Pool :: node()) -> ok.
stop(Pool) ->
    gen_fsm:sync_send_all_state_event(Pool, stop).

init(Args) ->
    process_flag(trap_exit, true),
    Waiting = queue:new(),
    Monitors = ets:new(monitors, [private]),
    init(Args, #state{waiting=Waiting, monitors=Monitors}).

init([{worker_module, Mod} | Rest], State) when is_atom(Mod) ->
    {ok, Sup} = poolboy_sup:start_link(Mod, Rest),
    init(Rest, State#state{supervisor=Sup});
init([{size, Size} | Rest], State) when is_integer(Size) ->
    init(Rest, State#state{size=Size});
init([{max_overflow, MaxOverflow} | Rest], State) when is_integer(MaxOverflow) ->
    init(Rest, State#state{max_overflow=MaxOverflow});
init([_ | Rest], State) ->
    init(Rest, State);
init([], #state{size=Size, supervisor=Sup, max_overflow=MaxOverflow}=State) ->
    Workers = prepopulate(Size, Sup),
    StartState = case {Size, MaxOverflow} of
        {0, 0} -> full;
        {0, _} -> overflow;
        {_, _} -> ready
    end,
    {ok, StartState, State#state{workers=Workers}}.

ready({checkin, Pid}, State) ->
    Monitors = State#state.monitors,
    case ets:lookup(Monitors, Pid) of
        [{Pid, Ref}] ->
            true = erlang:demonitor(Ref),
            true = ets:delete(Monitors, Pid),
            Workers = queue:in(Pid, State#state.workers),
            {next_state, ready, State#state{workers=Workers}};
        [] ->
            {next_state, ready, State}
    end;
ready(_Event, State) ->
    {next_state, ready, State}.

ready({checkout, Block, Timeout}, {FromPid, _}=From, State) ->
    #state{supervisor = Sup,
           workers = Workers,
           monitors = Monitors,
           max_overflow = MaxOverflow} = State,
    case queue:out(Workers) of
        {{value, Pid}, Left} ->
            Ref = erlang:monitor(process, FromPid),
            true = ets:insert(Monitors, {Pid, Ref}),
            NextState = case {queue:len(Left), MaxOverflow} of
                {0, 0} -> full;
                {0, _} -> overflow;
                {_, _} -> ready
            end,
            {reply, Pid, NextState, State#state{workers=Left}};
        {empty, Empty} when MaxOverflow > 0 ->
            {Pid, Ref} = new_worker(Sup, FromPid),
            true = ets:insert(Monitors, {Pid, Ref}),
            {reply, Pid, overflow, State#state{workers=Empty, overflow=1}};
        {empty, Empty} when Block =:= false ->
            {reply, full, full, State#state{workers=Empty}};
        {empty, Empty} ->
            Waiting = add_waiting(From, Timeout, State#state.waiting),
            {next_state, full, State#state{workers=Empty, waiting=Waiting}}
    end;
ready(_Event, _From, State) ->
    {reply, ok, ready, State}.

overflow({checkin, Pid}, #state{overflow=0}=State) ->
    Monitors = State#state.monitors,
    case ets:lookup(Monitors, Pid) of
        [{Pid, Ref}] ->
            true = erlang:demonitor(Ref),
            true = ets:delete(Monitors, Pid),
            NextState = case State#state.size > 0 of
                true  -> ready;
                false -> overflow
            end,
            Workers = queue:in(Pid, State#state.workers),
            {next_state, NextState, State#state{overflow=0, workers=Workers}};
        [] ->
            {next_state, overflow, State}
    end;
overflow({checkin, Pid}, State) ->
    #state{supervisor=Sup, monitors=Monitors, overflow=Overflow} = State,
    case ets:lookup(Monitors, Pid) of
        [{Pid, Ref}] ->
            ok = dismiss_worker(Sup, Pid),
            true = erlang:demonitor(Ref),
            true = ets:delete(Monitors, Pid),
            {next_state, overflow, State#state{overflow=Overflow-1}};
        [] ->
            {next_state, overflow, State}
    end;
overflow(_Event, State) ->
    {next_state, overflow, State}.

overflow({checkout, Block, Timeout}, From,
         #state{overflow=Overflow,
                max_overflow=MaxOverflow}=State) when Overflow >= MaxOverflow ->
    case Block of
        false ->
            {reply, full, full, State};
        Block ->
            Waiting = add_waiting(From, Timeout, State#state.waiting),
            {next_state, full, State#state{waiting=Waiting}}
    end;
overflow({checkout, _Block, _Timeout}, {From, _}, State) ->
    #state{supervisor = Sup,
           overflow = Overflow,
           max_overflow = MaxOverflow} = State,
    {Pid, Ref} = new_worker(Sup, From),
    true = ets:insert(State#state.monitors, {Pid, Ref}),
    NextState = case Overflow+1 >= MaxOverflow of
        true  -> full;
        false -> overflow
    end,
    {reply, Pid, NextState, State#state{overflow=Overflow+1}};
overflow(_Event, _From, State) ->
    {reply, ok, overflow, State}.

full({checkin, Pid}, State) ->
    #state{supervisor = Sup,
           waiting = Waiting,
           monitors = Monitors,
           max_overflow = MaxOverflow,
           overflow = Overflow} = State,
    case ets:lookup(Monitors, Pid) of
        [{Pid, Ref}] ->
            true = erlang:demonitor(Ref),
            true = ets:delete(Monitors, Pid),
            case queue:out(Waiting) of
                {{value, {{FromPid, _}=From, Timeout, StartTime}}, Left} ->
                    case wait_valid(StartTime, Timeout) of
                        true ->
                            Ref1 = erlang:monitor(process, FromPid),
                            true = ets:insert(Monitors, {Pid, Ref1}),
                            gen_fsm:reply(From, Pid),
                            {next_state, full, State#state{waiting=Left}};
                        false ->
                            full({checkin, Pid}, State#state{waiting=Left})
                    end;
                {empty, Empty} when MaxOverflow < 1 ->
                    Workers = queue:in(Pid, State#state.workers),
                    {next_state, ready, State#state{workers=Workers,
                                                    waiting=Empty}};
                {empty, Empty} ->
                    ok = dismiss_worker(Sup, Pid),
                    {next_state, overflow, State#state{waiting=Empty,
                                                       overflow=Overflow-1}}
            end;
        [] ->
            {next_state, full, State}
    end;
full(_Event, State) ->
    {next_state, full, State}.

full({checkout, false, _Timeout}, _From, State) ->
    {reply, full, full, State};
full({checkout, _Block, Timeout}, From, State) ->
    Waiting = add_waiting(From, Timeout, State#state.waiting),
    {next_state, full, State#state{waiting=Waiting}};
full(_Event, _From, State) ->
    {reply, ok, full, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(status, _From, StateName, State) ->
    {reply, {StateName, queue:len(State#state.workers), State#state.overflow,
             ets:info(State#state.monitors, size)},
     StateName, State};
handle_sync_event(get_avail_workers, _From, StateName, State) ->
    Workers = State#state.workers,
    WorkerList = queue:to_list(Workers),
    {reply, WorkerList, StateName, State};
handle_sync_event(get_all_workers, _From, StateName, State) ->
    Sup = State#state.supervisor,
    WorkerList = supervisor:which_children(Sup),
    {reply, WorkerList, StateName, State};
handle_sync_event(get_all_monitors, _From, StateName, State) ->
    Monitors = ets:tab2list(State#state.monitors),
    {reply, Monitors, StateName, State};
handle_sync_event(stop, _From, _StateName, State) ->
    Sup = State#state.supervisor,
    true = exit(Sup, shutdown),
    {stop, normal, ok, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = {error, invalid_message},
    {reply, Reply, StateName, State}.

handle_info({'DOWN', Ref, _, _, _}, StateName, State) ->
    case ets:match(State#state.monitors, {'$1', Ref}) of
        [[Pid]] ->
            true = exit(Pid, kill),
            {next_state, StateName, State};
        [] ->
            {next_state, StateName, State}
    end;
handle_info({'EXIT', Pid, Reason}, StateName, State) ->
    #state{supervisor = Sup,
           overflow = Overflow,
           waiting = Waiting,
           monitors = Monitors,
           max_overflow = MaxOverflow} = State,
    case ets:lookup(Monitors, Pid) of
        [{Pid, Ref}] ->
            true = erlang:demonitor(Ref),
            true = ets:delete(Monitors, Pid),
            case StateName of
                ready ->
                    W = queue:filter(fun (P) -> P =/= Pid end, State#state.workers),
                    {next_state, ready, State#state{workers=queue:in(new_worker(Sup), W)}};
                overflow when Overflow =:= 0 ->
                    W = queue:filter(fun (P) -> P =/= Pid end, State#state.workers),
                    {next_state, ready, State#state{workers=queue:in(new_worker(Sup), W)}};
                overflow ->
                    {next_state, overflow, State#state{overflow=Overflow-1}};
                full when MaxOverflow < 1 ->
                    case queue:out(Waiting) of
                        {{value, {{FromPid, _}=From, Timeout, StartTime}}, LeftWaiting} ->
                            case wait_valid(StartTime, Timeout) of
                                true ->
                                    MonitorRef = erlang:monitor(process, FromPid),
                                    NewWorker = new_worker(Sup),
                                    true = ets:insert(Monitors, {NewWorker, MonitorRef}),
                                    gen_fsm:reply(From, NewWorker),
                                    {next_state, full, State#state{waiting=LeftWaiting}};
                                false ->
                                    handle_info({'EXIT', Pid, Reason}, StateName, State#state{waiting=LeftWaiting})
                            end;
                        {empty, Empty} ->
                            Workers2 = queue:in(new_worker(Sup), State#state.workers),
                            {next_state, ready, State#state{waiting=Empty,
                                                            workers=Workers2}}
                    end;
                full when Overflow =< MaxOverflow ->
                    case queue:out(Waiting) of
                        {{value, {{FromPid, _}=From, Timeout, StartTime}}, LeftWaiting} ->
                            case wait_valid(StartTime, Timeout) of
                                true ->
                                    MonitorRef = erlang:monitor(process, FromPid),
                                    NewWorker = new_worker(Sup),
                                    true = ets:insert(Monitors, {NewWorker, MonitorRef}),
                                    gen_fsm:reply(From, NewWorker),
                                    {next_state, full, State#state{waiting=LeftWaiting}};
                                _ ->
                                    handle_info({'EXIT', Pid, Reason}, StateName, State#state{waiting=LeftWaiting})
                            end;
                        {empty, Empty} ->
                            {next_state, overflow, State#state{overflow=Overflow-1,
                                                               waiting=Empty}}
                    end;
                full ->
                    {next_state, full, State#state{overflow=Overflow-1}}
            end;
        [] ->
            case queue:member(Pid, State#state.workers) of
                true ->
                    W = queue:filter(fun (P) -> P =/= Pid end, State#state.workers),
                    {next_state, StateName, State#state{workers=queue:in(new_worker(Sup), W)}};
                false ->
                    {next_state, StateName, State}
            end
    end;
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

new_worker(Sup) ->
    {ok, Pid} = supervisor:start_child(Sup, []),
    true = link(Pid),
    Pid.

new_worker(Sup, FromPid) ->
    Pid = new_worker(Sup),
    Ref = erlang:monitor(process, FromPid),
    {Pid, Ref}.

dismiss_worker(Sup, Pid) ->
    true = unlink(Pid),
    supervisor:terminate_child(Sup, Pid).

prepopulate(0, _) ->
    queue:new();
prepopulate(N, Sup) ->
    prepopulate(N, Sup, queue:new()).

prepopulate(0, _, Workers) ->
    Workers;
prepopulate(N, Sup, Workers) ->
    prepopulate(N-1, Sup, queue:in(new_worker(Sup), Workers)).

add_waiting(Pid, Timeout, Queue) ->
    queue:in({Pid, Timeout, os:timestamp()}, Queue).

wait_valid(infinity, _) ->
    true;
wait_valid(StartTime, Timeout) ->
    Waited = timer:now_diff(os:timestamp(), StartTime),
    (Waited div 1000) < Timeout.