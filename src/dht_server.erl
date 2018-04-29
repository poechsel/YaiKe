-module(dht_server).
-include("dht.hrl").
-behaviour(gen_server).

-export([start_link/2, ping/1, debug/0, find_node/1, store/1, find_value/1, broadcast/0]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).

%%% Client API
start_link(K, Alpha) ->
    io:format("~p ~p~n", [K, Alpha]),
    io:format("uid: ~p~n", [dht_utils:hash(node())]),
    dht_routing_sup:start_link([K, Alpha, dht_utils:hash(node())]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha], []).

ping({_, Other}) ->
    gen_server_call(?MODULE, {request_ping, Other}, 1000);

ping(Other) ->
    io:format("Starting ping~n"),
    Uid = dht_utils:hash(Other),
    X = ping({Uid, Other}),
    io:format("Stopping ping~n"),
    X.

debug() ->
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
    io:format("RESULT ~n~p~nENDRESULT~n", [R]),
    R.

find_value(Hash) ->
    gen_server_call(?MODULE, {lookup_value, Hash}, 10000).

store(Value) ->
    Hash = dht_utils:hash(Value),
    Nodes = find_node(Hash),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store, {Hash, Value}}) end,
              Nodes),
    Hash.


lookup_nodes_wrapper(Owner_pid, {_, Owner_ip} = Owner, Target) ->
    Out = 
    case gen_server_call({?MODULE, Owner_ip}, {request_k_nearest, Owner, Target}, 1000) of
        {error, _} ->
            [];
        Received ->
            dht_routing:update(Owner),
            Received
    end,
    Owner_pid ! Out.

lookup_nodes_loop(_Target, _From, Old, _Seen, Expected, _K) when Expected =< 0 ->
    Old;

lookup_nodes_loop(Target, _From, Old, Seen, Expected, K) ->
    Me = self(),
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Target) =< (U2 bxor Target) end,
    Sorted = receive
                 Received -> lists:sort(Fun, Received)
             end,
    Current = lists:sublist(lists:usort(Fun, lists:merge(Fun, Old, Sorted)), K),
    Unvisited = lists:filter(fun (O) -> not(sets:is_element(O, Seen)) end, Current),
    case (Unvisited =:= []) of
        true ->
            lookup_nodes_loop(Target, _From, Current, Seen, Expected - 1, K);
        false ->
            [ Next | _ ] = Unvisited,
            spawn(fun () -> lookup_nodes_wrapper(Me, Next, Target) end),
            New_seen = sets:add_element(Next, Seen),
            lookup_nodes_loop(Target, _From, Current, New_seen, Expected, K)
    end.

lookup_nodes(Hash, _From, K, Alpha) ->
    Me = self(),
    Start = dht_routing:find_k_nearest(Hash, Alpha),
    Seen = sets:from_list(Start),
    lists:map(fun (Node) ->
        spawn(fun () -> lookup_nodes_wrapper(Me, Node, Hash) end) end,
        Start
    ),
    Nearest = lookup_nodes_loop(Hash, _From, Start, Seen, length(Start), K),
    gen_server:reply(_From, Nearest).




lookup_value_wrapper(Owner_pid, {_, Owner_ip} = Owner, Hash) ->
    Present = gen_server_call({?MODULE, Owner_ip}, {store_contains, Owner, Hash}, 1000),
    case Present of 
        { error, _ } ->
            Owner_pid ! { notfound, [] };
        { found, Value } ->
            Owner_pid ! { found, Value };
        { notfound } ->
            Out = case gen_server_call({?MODULE, Owner_ip}, {request_k_nearest, Owner, Hash}, 1000) of
                {error, _} ->
                    [];
                Received ->
                    Received
            end,
            Owner_pid ! { notfound, Out }
    end.

lookup_value_loop(_Target, _From, _Old, _Seen, Expected, _K) when Expected =< 0 ->
    { notfound };

lookup_value_loop(Target, _From, Old, Seen, Expected, K) ->
    Me = self(),
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Target) =< (U2 bxor Target) end,
    receive
        { found, Value } ->
            { found, Value };
        { notfound, Received } ->
            Sorted = lists:sort(Fun, Received),
            Current = lists:sublist(lists:usort(Fun, lists:merge(Fun, Old, Sorted)), K),
            Unvisited = lists:filter(fun (O) -> not(sets:is_element(O, Seen)) end, Current),
            case (Unvisited =:= []) of
                true ->
                    lookup_value_loop(Target, _From, Current, Seen, Expected - 1, K);
                false ->
                    [ Next | _ ] = Unvisited,
                    spawn(fun () -> lookup_value_wrapper(Me, Next, Target) end),
                    New_seen = sets:add_element(Next, Seen),
                    lookup_value_loop(Target, _From, Current, New_seen, Expected, K)
            end
    end.

lookup_value(Hash, _From, K, Alpha) ->
    Me = self(),
    Start = dht_routing:find_k_nearest(Hash, Alpha),
    Seen = sets:from_list(Start),
    lists:map(fun (Node) ->
        spawn(fun () -> lookup_value_wrapper(Me, Node, Hash) end) end,
        Start
    ),
    Nearest = lookup_value_loop(Hash, _From, Start, Seen, length(Start), K),
    gen_server:reply(_From, Nearest).




%%% Server functions
init([K, Alpha]) -> 
    timer:send_interval(erlang:convert_time_unit(10, second, millisecond), refresh_table),
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


handle_call({request_ping, Other}, _From, State) ->
    gen_server:cast({?MODULE, Other}, {ping, {State#state.uid, node()}, _From}),
    { noreply, State };

handle_call({request_k_nearest, Node, Target}, _From, State) ->
    dht_routing:update(Node),
    Nearest = dht_routing:find_k_nearest(Target, State#state.k),
    { reply, Nearest, State };

handle_call({store_contains, Node, Hash}, _From, State) ->
    dht_routing:update(Node),
    Out = case maps:find(Hash, State#state.store) of
              error ->
                  { notfound };
              { ok, Value } ->
                  { found, Value }
          end,
    { reply, Out, State };


handle_call({lookup_value, Hash}, _From, State) ->
    spawn(fun () -> lookup_value(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State};

handle_call({lookup_nodes, Hash}, _From, State) ->
    spawn(fun () -> lookup_nodes(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State}.


handle_cast({store, {Hash, Value}}, State) ->
    Store = maps:put(Hash, Value, State#state.store),
    { noreply, State#state{store=Store} };


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
    NewState = case (maps:find(Ref, FState#state.queries)) of
                   error ->
                       NS = handle_broadcast(Msg, FState),
                       dht_routing:iter(fun (I, Bucket) ->
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
    io:format("Broadcast received on ~p~n", [node()]),
    State.


handle_info(refresh_table, State) ->
    CTime = dht_utils:time_now(),
    OffsetTime = erlang:convert_time_unit(50, second, millisecond),
    Representants = dht_routing:get_representant_bucket(
                      fun (Time) -> (CTime - Time) < OffsetTime end),
    lists:foreach(
      fun ({H, Ip}) ->
              io:format("[~p]: refreshing: ~p ~p~n", [node(), H, Ip]),
              spawn(fun () -> gen_server_call(?MODULE, {lookup_nodes, H}, 10000) end)
      end,
                  Representants),
    { noreply, State };

handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

terminate(normal, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    io:format("code updated~n"),
    %% No change planned. The function is there for the behaviour,
    %% but will not be used. Only a version on the next
    {ok, State}. 
