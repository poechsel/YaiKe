-module(dht_server).
-include("dht.hrl").
-behaviour(gen_server).

-export([start_link/2, ping/1, debug/0, find_node/1, find_node/2, store/1, find_value/1, broadcast/0, remove/1]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).

%%% Client API
start_link(K, Alpha) ->
    dht_routing_sup:start_link([K, Alpha, dht_utils:hash(node())]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha], []).

ping({_, Other}) ->
    gen_server_call(?MODULE, {request_ping, Other}, 1000);

ping(Other) ->
    Uid = dht_utils:hash(Other),
    X = ping({Uid, Other}),
    X.

debug() ->
    gen_server:call(?MODULE, debug),
    dht_routing:debug().

broadcast() ->
    gen_server:cast(?MODULE, {broadcast, make_ref(), "a", 0}).



gen_server_call(A, B, C) ->
    try
        gen_server:call(A, B, C)
    catch
        exit:{{nodedown, _}, _} ->
            {error, nodedown};
        exit:{timeout, _} ->
            {error, timeout};
        _:x ->  
            {error, timeout}
    end.


find_node(Target) ->
    R = gen_server_call(?MODULE, {lookup_nodes, Target}, 10000),
    R.

find_node(Target, Fun) ->
    R = gen_server_call(?MODULE, {lookup_nodes, Fun, Target}, 10000),
    R.

find_value(Hash) ->
    gen_server_call(?MODULE, {lookup_value, Hash}, 10000).

store(Value) ->
    Hash = dht_utils:hash(Value),
    Nodes = find_node(Hash),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store, {Hash, Value}}) end,
              Nodes),
    Hash.

store_remove_util(Hash) ->
    Nodes = find_node(Hash, (fun (K) -> 4 * K end)),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store_remove, Hash}) end, Nodes).

remove(Hash) ->
    gen_server:cast(?MODULE, {remove, Hash}).
    


request_k_nearest_wrapper(K, {_, Owner_ip} = Owner, Target) ->
    case gen_server_call({?MODULE, Owner_ip}, {request_k_nearest, K, Owner, Target}, 1000) of
        {error, _} ->
            [];
        Received ->
            dht_routing:update(Owner),
            Received
    end.



lookup_nodes_wrapper(Owner_pid, Owner, Target, K) ->
    Out = request_k_nearest_wrapper(K, Owner, Target),
    Owner_pid ! Out.

lookup_value_wrapper(Owner_pid, {_, Owner_ip} = Owner, Hash, K) ->
    Present = gen_server_call({?MODULE, Owner_ip}, {store_contains, Owner, Hash}, 1000),
    case Present of 
        { error, _ } ->
            Owner_pid ! { notfound, [] };
        { found, Value } ->
            Owner_pid ! { found, Value };
        { notfound } ->
            Out = request_k_nearest_wrapper(K, Owner, Hash),
            Owner_pid ! { notfound, Out }
    end.

meta_lookup_loop(_, _, Old, _, Expected, _, {_, _, Fun_default}) when Expected =< 0 ->
    Fun_default(Old);
meta_lookup_loop(T, F, O, S, E, K, {_, Fun_loop, _} = Spe) ->
    Fun_loop((fun (Received) -> 
            meta_lookup_loop_act(Received, T, F, O, S, E, K, Spe) end)).

meta_lookup_loop_act(Received, Target, From, Old, Seen, Expected, K, {Fun_wrapper, _, _} = Spe) ->
    Me = self(),
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Target) =< (U2 bxor Target) end,
    Sorted = lists:sort(Fun, Received),
    Current = lists:sublist(lists:usort(Fun, lists:merge(Fun, Old, Sorted)), K),
    Unvisited = lists:filter(fun (O) -> not(sets:is_element(O, Seen)) end, Current),
    case (Unvisited =:= []) of
        true ->
            meta_lookup_loop(Target, From, Current, Seen, Expected - 1, K, Spe);
        false ->
            [ Next | _ ] = Unvisited,
            spawn(fun () -> Fun_wrapper(Me, Next, Target, K) end),
            New_seen = sets:add_element(Next, Seen),
            meta_lookup_loop(Target, From, Current, New_seen, Expected, K, Spe)
    end.

meta_lookup(Hash, From, K, Alpha, {Fun_wrapper, _, _} = Specialization) ->
    Me = self(),
    Start = dht_routing:find_k_nearest(Hash, Alpha),
    Seen = sets:from_list(Start),
    lists:map(fun (Node) ->
        spawn(fun () -> Fun_wrapper(Me, Node, Hash, K) end) end,
        Start
    ),
    Nearest = meta_lookup_loop(Hash, From, Start, Seen, length(Start), K, Specialization),
    gen_server:reply(From, Nearest).


lookup_nodes(Hash, _From, K, Alpha) ->
    meta_lookup(Hash, _From, K, Alpha, {
        (fun(M,N,H,K_) -> lookup_nodes_wrapper(M,N,H,K_) end), 
        (fun (Continuation) ->
            receive
                R -> Continuation(R)
            end
            end 
        ),
        (fun (O) -> O end)}).


lookup_value(Hash, _From, K, Alpha) ->
    meta_lookup(Hash, _From, K, Alpha, {
        (fun(M,N,H,K_) -> lookup_value_wrapper(M,N,H,K_) end), 
        (fun (Continuation) ->
            receive
                { found, _ } = O -> O;
                { notfound, R } -> Continuation(R)
            end
            end 
        ),
        (fun (_) -> { notfound } end)}).


store_refresh(Self, Hash, Value) ->
    Nodes = find_node(Hash),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store, {Hash, Value}}) end,
              Nodes),
    case lists:member(Self, Nodes) of
        false ->
            gen_server:cast(?MODULE, {store_remove, Hash});
        true ->
            1
    end.


%%% Server functions
init([K, Alpha]) -> 
    timer:send_after(erlang:convert_time_unit(10, second, millisecond), store_refresh_init),
    timer:send_interval(erlang:convert_time_unit(10, second, millisecond), refresh_table),
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


handle_call({request_ping, Other}, _From, State) ->
    gen_server:cast({?MODULE, Other}, {ping, {State#state.uid, node()}, _From}),
    { noreply, State };

handle_call({request_k_nearest, K, Node, Target}, _From, State) ->
    dht_routing:update(Node),
    Nearest = dht_routing:find_k_nearest(Target, K),
    { reply, Nearest, State };

handle_call({store_contains, Node, Hash}, _From, State) ->
    dht_routing:update(Node),
    Out = case maps:find(Hash, State#state.store) of
              error ->
                  { notfound };
              { ok, {_, Value} } ->
                  { found, Value }
          end,
    { reply, Out, State };

handle_call(debug, _From, State) ->
    { reply, 1, State };


handle_call({lookup_value, Hash}, _From, State) ->
    spawn(fun () -> lookup_value(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State};

handle_call({lookup_nodes, Hash}, _From, State) ->
    spawn(fun () -> lookup_nodes(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State};

handle_call({lookup_nodes, Fun, Hash}, _From, State) ->
    spawn(fun () -> lookup_nodes(Hash, _From, Fun(State#state.k), State#state.alpha) end),
    {noreply, State}.

handle_cast({store, {Hash, Value}}, State) ->
    Store = maps:put(Hash, { dht_utils:time_now(), Value}, State#state.store),
    { noreply, State#state{store=Store} };

handle_cast({remove, Hash}, State) ->
    timer:send_after(erlang:convert_time_unit(60*60, second, millisecond), {store_remove_call, Hash}),
    timer:send_after(erlang:convert_time_unit(60*60 + 30 * 60, second, millisecond), {store_remove_call, Hash}),
    spawn(fun () -> store_remove_util(Hash) end),
    { noreply, State };

handle_cast({store_remove, Hash}, State) ->
    Store = maps:remove(Hash, State#state.store),
    { noreply, State#state{store=Store }};


handle_cast({ping, {_, Ip} = Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:cast({?MODULE, Ip}, {pong, {State#state.uid, node()}, _From}),
    { noreply, State };

handle_cast({pong, Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:reply(_From, ok),
    { noreply, State };

handle_cast({broadcast, Ref, Msg, Height}, State) ->
    OffsetTime = erlang:convert_time_unit(60*60, second, millisecond),
    CTime = dht_utils:time_now(),
    FQueries = maps:filter(
               fun (_, Time) -> (CTime - Time) < OffsetTime end,
               State#state.queries),
    FState = State#state{queries=FQueries},
    NewState = 
    case (maps:find(Ref, FState#state.queries)) of
        error ->
            NS = handle_broadcast(Msg, FState),
            dht_routing:iter(
              fun (I, Bucket) ->
                      case (I >= Height) and (length(Bucket) > 0) of 
                          true ->
                              {_, Ip} = lists:nth(rand:uniform(length(Bucket)), Bucket),
                              gen_server:cast({?MODULE, Ip}, {broadcast, Ref, Msg, I+1})
                              ;
                          _ -> 1
                      end
              end
             ),
            NS;
        { ok, _ } -> FState
    end,
    { noreply, NewState#state{queries=maps:put(Ref, dht_utils:time_now(), NewState#state.queries)} }
.

handle_broadcast(_, State) ->
    State.


handle_info(refresh_table, State) ->
    CTime = dht_utils:time_now(),
    OffsetTime = erlang:convert_time_unit(50, second, millisecond),
    Representants = dht_routing:get_representant_bucket(
                      fun (Time) -> (CTime - Time) < OffsetTime end),
    lists:foreach(
      fun ({H, _}) ->
              spawn(fun () -> gen_server_call(?MODULE, {lookup_nodes, H}, 10000) end)
      end,
      Representants),
    { noreply, State };

handle_info({store_remove_call, Hash}, State) ->
    spawn(fun() -> store_remove_util(Hash) end),
    {noreply, State};

handle_info(store_refresh, State) ->
    CTime = dht_utils:time_now(),
    OffsetTime = erlang:convert_time_unit(50, second, millisecond),
    L = maps:to_list(State#state.store),
    Lf = lists:filter(fun ({_, {Time, _}}) -> (CTime - Time) < OffsetTime end, L),
    lists:foreach(
      fun ({H, {_, V}}) -> spawn(fun () -> store_refresh({State#state.uid, node()}, H, V) end) end,
      Lf),
    { noreply, State };

handle_info(store_refresh_init, State) ->
    io:format("coucou~n"),
    timer:send_interval(erlang:convert_time_unit(10, second, millisecond), store_refresh),
    {noreply, State};


handle_info(Msg, State) ->
    io:format("unexpected message [~p]~n", [Msg]),
    {noreply, State}.

terminate(normal, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    %% No change planned. The function is there for the behaviour,
    %% but will not be used. Only a version on the next
    {ok, State}. 
