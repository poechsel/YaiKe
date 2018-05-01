-module(dht_server).
-include("dht.hrl").
-behaviour(gen_server).

-export([start_link/2, ping/1, stats/0, store/1, pull/1, broadcast/1, scatter/1, remove/1, connect/1]).
-export([init/1, handle_cast/2, handle_info/2, handle_call/3,
         terminate/2, code_change/3]).



%% PUBLIC FUNCTINONS



init([K, Alpha]) -> 
    % first, set the offset for store refresh loop. This offset is here to avoid that several nodes refreshes their
    % store at the same time when starting at the same moment
    timer:send_after(erlang:convert_time_unit(rand:uniform(15*6) * 10, second, millisecond), store_refresh_init),
    % set up the interval of table refresh cases (one per hour)
    timer:send_interval(erlang:convert_time_unit(60*60, second, millisecond), refresh_table),
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


terminate(normal, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    %% No change planned. The function is there for the behaviour,
    %% but will not be used. Only a version on the next
    {ok, State}. 

%% start the current node
start_link(K, Alpha) ->
    dht_routing_sup:start_link([K, Alpha, dht_utils:hash(node())]),
    dht_routing:update({dht_utils:hash(node()), node()}),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha], []).


%% @doc connect this node to another node 'Node'
connect(Other) ->
    gen_server:cast(?MODULE, {connect, Other}).

%% @doc get statistics from this node
stats() ->
    RT = gen_server:call(?MODULE, stats),
    {dht_routing:stats(), RT}.


%% @doc broadcast a message
broadcast(Msg) ->
    gen_server:cast(?MODULE, {broadcast, make_ref(), Msg, 0}).

%% @doc scatter some messages
scatter(MsgList) ->
    gen_server:cast(?MODULE, {broadcast, make_ref(), {scatter, MsgList}, 0}).


%% @doc ping a node
ping({_, Other}) ->
    gen_server_call(?MODULE, {request_ping, Other}, 1000);

ping(Other) ->
    Uid = dht_utils:hash(Other),
    X = ping({Uid, Other}),
    X.

%% @doc pull (ie get) the value associated to the hash 'Hash'
pull(Hash) ->
    gen_server_call(?MODULE, {lookup_value, Hash}, 10000).

%% @doc store a value on the dht
store(Value) ->
    Hash = dht_utils:hash(Value),
    Nodes = find_node(Hash),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store, {Hash, Value}}) end,
              Nodes),
    Hash.


%% @doc remove a value from the dht
remove(Hash) ->
    gen_server:cast(?MODULE, {remove, Hash}).
    



%% -------------- inner functions -------------

%% @doc overlay on gen_server:call to deal with exceptions nicely
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


%% @doc true if the argument is not an error
is_not_error({error, _}) ->
    false;
is_not_error(_) ->
    true.

%% @doc find the K nearest nodes to the Target
find_node(Target) ->
    R = gen_server_call(?MODULE, {lookup_nodes, Target}, 10000),
    case R of 
        { error, _ } -> [];
        L -> lists:filter(fun (X) -> is_not_error(X) end, L)
    end.

%% @doc find the Fun(K) nearest nodes to the Target
find_node(Target, Fun) ->
    R = gen_server_call(?MODULE, {lookup_nodes, Fun, Target}, 10000),
    case R of 
        { error, _ } -> [];
        L -> lists:filter(fun (X) -> is_not_error(X) end, L)
    end.


%% @doc utility function used to remove a value from the dht
store_remove_util(Hash) ->
    Nodes = find_node(Hash, (fun (K) -> 4 * K end)),
    lists:map(fun ({_, Ip}) -> gen_server:cast({?MODULE, Ip}, {store_remove, Hash}) end, Nodes).


%% @doc wrapper for the call to get the k nearest nodes known by the current node
request_k_nearest_wrapper(K, {_, Owner_ip} = Owner, Target) ->
    case gen_server_call({?MODULE, Owner_ip}, {request_k_nearest, K, Owner, Target}, 1000) of
        {error, _} ->
            [];
        Received ->
            dht_routing:update(Owner),
            Received
    end.



%% @doc node lookup loop
meta_lookup_loop(_, _, Old, _, Expected, _, {_, _, Fun_default}) when Expected =< 0 ->
    Fun_default(Old);
meta_lookup_loop(T, F, O, S, E, K, {_, Fun_loop, _} = Spe) ->
    % Fun_loop indicates how subresults should be treated. 
    % It is passed a function as argument which will continue the search of nodes
    Fun_loop((fun (Received) -> 
            meta_lookup_loop_act(Received, T, F, O, S, E, K, Spe) end)).

%% @doc 'Received' is the last piece of informations we got in order to improve our result
%% 'Target' is the hash we want to get the nearest 'K' neighbours. 'Expected' is the number of 
%% sub results we are still waiting for (it's a parallelisation factor), 'From' the caller of the 
%% lookup algorithm. 'Old' the current result which we want to improve and 'Seen' the list of nodes 
%% already treated in the search.
%% Spe is a tupple of functions to specialize this "meta lookup"
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

%% @doc meta node/value lookup, which will be specialized latter on
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



%% @doc for node lookup, when we are getting a sub result, we want to send it back
lookup_nodes_wrapper(Owner_pid, Owner, Target, K) ->
    Out = request_k_nearest_wrapper(K, Owner, Target),
    Owner_pid ! Out.

%% @doc node lookup
lookup_nodes(Hash, _From, K, Alpha) ->
    meta_lookup(Hash, _From, K, Alpha, {
        % wrapper function
        (fun(M,N,H,K_) -> lookup_nodes_wrapper(M,N,H,K_) end), 
        % we want to always continue the search when we are getting a new subresult
        (fun (Continuation) ->
            receive
                R -> Continuation(R)
            end
            end 
        ),
        % when the search is done, return the arrays of the k nearest nodes
        (fun (O) -> O end)}).

%% @doc for value lookups we want to return 'found, Value' if the current node we
%% are observing contains the hash we are looking for
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

%% @doc value lookup
lookup_value(Hash, _From, K, Alpha) ->
    meta_lookup(Hash, _From, K, Alpha, {
        (fun(M,N,H,K_) -> lookup_value_wrapper(M,N,H,K_) end), 
        % we want to stop the search when the value is found
        (fun (Continuation) ->
            receive
                { found, _ } = O -> O;
                { notfound, R } -> Continuation(R)
            end
            end 
        ),
        % when the search is done, it means that we didn't found the node
        (fun (_) -> { notfound } end)}).


%% @doc refresh the store
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








%% -------------- CALLs ----------



%% @doc request a ping
handle_call({request_ping, Other}, _From, State) ->
    gen_server:cast({?MODULE, Other}, {ping, {State#state.uid, node()}, _From}),
    { noreply, State };

%% @doc request a call to find the k known nearest neighbors
handle_call({request_k_nearest, K, Node, Target}, _From, State) ->
    dht_routing:update(Node),
    Nearest = dht_routing:find_k_nearest(Target, K),
    { reply, Nearest, State };

%% @doc request by node 'Node' to know it the store contains a value
%% of hash 'Hash'
%% @returns { notfound } if it's not the case, else { found, value }
handle_call({store_contains, Node, Hash}, _From, State) ->
    dht_routing:update(Node),
    Out = case maps:find(Hash, State#state.store) of
              error ->
                  { notfound };
              { ok, {_, Value} } ->
                  { found, Value }
          end,
    { reply, Out, State };


%% @doc request for a list of statistics
handle_call(stats, _From, State) ->
    { reply, maps:size(State#state.store), State };


%% @doc request for a lookup of the value having hash 'Hash'
%% @returns A node storing a value having this hash
handle_call({lookup_value, Hash}, _From, State) ->
    spawn(fun () -> lookup_value(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State};

%% @doc request for the lookup of the K nearest neighbors to the node of hash 'Hash'
%% @returns a list of nodes
handle_call({lookup_nodes, Hash}, _From, State) ->
    spawn(fun () -> lookup_nodes(Hash, _From, State#state.k, State#state.alpha) end),
    {noreply, State};

%% @doc request for the lookup of the Fun(K) nearest neighbors to the node of hash 'Hash'
%% @returns a list of nodes
handle_call({lookup_nodes, Fun, Hash}, _From, State) ->
    spawn(fun () -> lookup_nodes(Hash, _From, Fun(State#state.k), State#state.alpha) end),
    {noreply, State}.





%% -------------- CASTS ----------



%% @doc store the couple {Hash, Value} on this node
handle_cast({store, {Hash, Value}}, State) ->
    Store = maps:put(Hash, { dht_utils:time_now(), Value}, State#state.store),
    { noreply, State#state{store=Store} };

%% @doc remove the value having hash 'Hash' from the DHT.
%% If the node is not present, do nothing
handle_cast({remove, Hash}, State) ->
    % because of the routing table and store refresh mechanism, we will also try in the future to 
    % delete this node (in one hour and one hour 30 to make sure that both occured)
    timer:send_after(erlang:convert_time_unit(60*60, second, millisecond), {store_remove_call, Hash}),
    timer:send_after(erlang:convert_time_unit(60*60 + 30 * 60, second, millisecond), {store_remove_call, Hash}),
    spawn(fun () -> store_remove_util(Hash) end),
    { noreply, State };


%% @doc remove the value having hash 'Hash' from this node
handle_cast({store_remove, Hash}, State) ->
    Store = maps:remove(Hash, State#state.store),
    { noreply, State#state{store=Store }};


%% @doc send a ping to node Node
handle_cast({ping, {_, Ip} = Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:cast({?MODULE, Ip}, {pong, {State#state.uid, node()}, _From}),
    { noreply, State };

%% @doc send back a pong to node Node
handle_cast({pong, Node, _From}, State) ->
    dht_routing:update(Node),
    gen_server:reply(_From, ok),
    { noreply, State };

%% @doc connect the current node to the node 'Other'
handle_cast({connect, Other}, State) ->
    spawn(
      fun () ->
              % first ping the other node
              ping(Other),
              % then ask for the nearest nodes to the current one
              find_node(State#state.uid),
              % then refresh the routing table
              R = dht_routing:get_representant_bucket(fun (_) -> true end),
              lists:foreach(
                fun ({H, _}) ->
                        spawn(fun () -> find_node(H) end)
                end,
                R)
      end),
    { noreply, State };


%% @doc broadcast 'Msg' through the DHT. 'Ref' is a uid refering to this broadcast call
handle_cast({broadcast, Ref, Msg, Height}, State) ->
    % first see if this broadcast was already seen and remove old broadcasts from the cache
    OffsetTime = erlang:convert_time_unit(60*60, second, millisecond),
    CTime = dht_utils:time_now(),
    FQueries = maps:filter(
               fun (_, Time) -> (CTime - Time) < OffsetTime end,
               State#state.queries),
    FState = State#state{queries=FQueries},
    NewState = 
    case (maps:find(Ref, FState#state.queries)) of
        error ->
            % if this broadcast wasn't seen, propagate it
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
    { noreply, NewState#state{queries=maps:put(Ref, dht_utils:time_now(), NewState#state.queries)} }.






%% -------------- BROADCASTS ----------
%% Handle broadcasts messages

%% @doc scattering is implemented as a broadcast
handle_broadcast({scatter, MessageList}, State) ->
    % select randomly a message from the message list
    % this should allow to distribute messages evenly on the dht
    Msg = lists:nth(rand:uniform(length(MessageList)), MessageList), 
    io:format("[~p] SCATTER: received ~p~n", [node(), Msg]),
    State;

%% @doc basic handler
handle_broadcast(Msg, State) ->
    io:format("[~p] BROADCAST: received ~p~n", [node(), Msg]),
    State.




 
%% -------------- INFO MESSAGES ----------
%% Dealts with other types of messages
%% More globally, deals with messages send by a timing mechanism


%% @doc refresh the routing table
handle_info(refresh_table, State) ->
    CTime = dht_utils:time_now(),
    % we want to refresh all buckets not accessed during the last hour
    OffsetTime = erlang:convert_time_unit(60*60, second, millisecond),
    Representants = dht_routing:get_representant_bucket(
                      fun (Time) -> (CTime - Time) < OffsetTime end),
    lists:foreach(
      fun ({H, _}) ->
              spawn(fun () -> find_node(H) end)
      end,
      Representants),
    { noreply, State };


%% @doc callback for removing an item from the store
handle_info({store_remove_call, Hash}, State) ->
    spawn(fun() -> store_remove_util(Hash) end),
    {noreply, State};


%% @doc Refresh the store (republish keys every hours)
handle_info(store_refresh, State) ->
    CTime = dht_utils:time_now(),
    % we don't want to republish keys that were added (or republished) recently
    OffsetTime = erlang:convert_time_unit(60*60, second, millisecond),
    L = maps:to_list(State#state.store),
    Lf = lists:filter(fun ({_, {Time, _}}) -> (CTime - Time) < OffsetTime end, L),
    lists:foreach(
      fun ({H, {_, V}}) -> spawn(fun () -> store_refresh({State#state.uid, node()}, H, V) end) end,
      Lf),
    { noreply, State };

%% @doc Prepare the store refreshing
handle_info(store_refresh_init, State) ->
    % set up the timer for the store refresh function
    timer:send_interval(erlang:convert_time_unit(60*60, second, millisecond), store_refresh),
    {noreply, State};

handle_info(Msg, State) ->
    io:format("unexpected message [~p]~n", [Msg]),
    {noreply, State}.

