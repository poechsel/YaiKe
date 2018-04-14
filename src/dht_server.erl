-module(dht_server).
-include("dht.hrl").
-behaviour(gen_server).

-export([start_link/2, ping/1, debug/0, find_node/1]).
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
    Ref = make_ref(),
    R = gen_server:call(?MODULE, {find_nodes, Target, Ref}),
    io:format("RESULT ~p~n~p~nENDRESULT~n", [Ref, R]),
    R.


%%% Server functions
init([K, Alpha]) -> 
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


handle_call({request_ping, Other}, _From, State) ->
    gen_server:cast({?MODULE, Other}, {ping, {State#state.uid, node()}, _From}),
    { noreply, State };

handle_call({find_nodes, Hash, Ref}, _From, State) ->
    Start = dht_routing:find_k_nearest(Hash, State#state.alpha),
    io:format("initializer ~p~n", [Start]),
    Seen = sets:from_list(Start),
    case length(Start) of
        0 -> 
            { reply, [], State};
        _ ->
            lists:map(fun ({_, Ip}) -> io:format("calling ~p~n", [Ip]),gen_server:cast({?MODULE, Ip}, {find_nodes_atom, {State#state.uid, node()}, Hash, Ref}) end, Start),
            Processing = maps:put(Ref,
                                  % missing nearest here TODO
                          #find_nodes_entry{from=_From, hash=Hash, seen=Seen},
                          State#state.processing),
            {noreply, State#state{processing=Processing}}
    end.

handle_cast({ping, {_, Ip} = Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:cast({?MODULE, Ip}, {pong, {State#state.uid, node()}, _From}),
    { noreply, State };

handle_cast({pong, Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:reply(_From, ok),
    { noreply, State };



handle_cast({find_nodes_atom, {_, Ip} = Node, Hash, Ref}, State) ->
    io:format("I was called to get atomic stuff~n"),
    dht_routing:update(Node),
    io:format("done updating dht table~n"),
    Nearest = dht_routing:find_k_nearest(Hash, State#state.k),
    io:format("Result of node ~p is ~p ~n", [node(), Nearest]),
    gen_server:cast({?MODULE, Ip}, {find_nodes_update, Nearest, Ref}),
    io:format("casting answer message~n"),
    { noreply, State };

handle_cast({find_nodes_update, Nearest, Ref}, State) ->
    io:format("updating informations on find node~n"),
    Processing = 
    case maps:find(Ref, State#state.processing) of
        {ok, Entry} ->
            Target = Entry#find_nodes_entry.hash,
            Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Target) =< (U2 bxor Target) end,
            Old = lists:sort(Fun, Entry#find_nodes_entry.nearest),
            Current = lists:sort(Fun, Nearest),
            io:format("RECEIVED ~p ~p ~n", [Old, Current]),
            Unvisited = lists:filter(fun (O) -> not(sets:is_element(O, Entry#find_nodes_entry.seen)) end, Current),
            case (Old =:= Current) or (Unvisited =:= []) of 
                true -> 
                    From = Entry#find_nodes_entry.from,
                    gen_server:reply(From, Current),
                    maps:remove(Ref, State#state.processing);
                false ->
                    % also send new ones (in theory)
                    [{_, Next_ip} = Next | _] = Unvisited,
                    gen_server:cast({?MODULE, Next_ip}, {find_nodes_atom, Next, Target, Ref}),
                    New = lists:sublist(lists:merge(Fun, Old, Current), State#state.k),
                    E = Entry#find_nodes_entry{nearest=New, seen=sets:add_element(Next, Entry#find_nodes_entry.seen)},
                    maps:update(Ref, E, State#state.processing)
            end;
        _ ->
            %io:format("BUUUUUUUUG~n"),
            State#state.processing
    end,
    { noreply, State#state{processing=Processing} }.


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
