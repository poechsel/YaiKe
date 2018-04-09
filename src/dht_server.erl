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
    Uid = dht_utils:hash(Other),
    ping({Uid, Other}).

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
    gen_server:cast(?MODULE, {find_nodes_init, Target, Ref}),
    receive
        {find_nodes_close, Ref_, Nearest} when Ref =:= Ref_ ->
            Nearest
    end.

find_nodes_iter(Target, Seen, Nearest_old, Ref, K) ->
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Target) =< (U2 bxor Target) end,
    receive 
        { find_nodes_upd, Nearest_news, Ref_Msg} when Ref_Msg =:= Ref ->
            Nearest_old_ = lists:sort(Fun, Nearest_old),
            Nearest_news_ = lists:sort(Fun, Nearest_news),
            case Nearest_old_ =:= Nearest_news_ of
                true -> 
                    Nearest_old_;
                false ->
                    Nearest = lists:sublist(lists:merge(Fun, Nearest_old_, Nearest_news_), K),
                    Nearest
            end
    end.


%%% Server functions
init([K, Alpha]) -> 
    {ok, #state{k=K, alpha=Alpha, uid = dht_utils:hash(node())}}.


handle_call({request_ping, Other}, _, State) ->
    T = gen_server_call({?MODULE, Other}, {ping, {State#state.uid, node()}}, 1000),
    Out = case T of 
              {pong, Target} -> dht_routing:update(Target), ok;
              {error, timeout} -> error;
              _ -> error
    end,
    { reply, Out, State };



handle_call({ping, Node}, _From, State) ->
    dht_routing:update(Node),
    { reply, {pong, {State#state.uid, node()}}, State }.




% temp
handle_cast({ask_k_nearest, {Uid, Ip}, Ref}, State) ->
    io:format("I was called, targeting ~p~n", [Ip]),
    Nearest = dht_routing:find_k_nearest(Uid, State#state.k),
    io:format("REACHING ~p~n", [Ip]),
    gen_server:cast({?MODULE, Ip}, {find_nodes_receive, Nearest, Ref}),
    io:format("REACHED ~p~n", [Ip]),
    { noreply, State };

handle_cast({find_nodes_init, Target, Ref}, State) ->
    Start_point = dht_routing:find_k_nearest(Target, State#state.alpha),
    Seen = sets:from_list(Start_point),
    io:format("RECEIVING FROM ~p ~p~n", [node(), self()]),
    lists:map(fun ({_Uid, Ip}) -> io:format("calling ~p~n", [Ip]),gen_server:cast({?MODULE, Ip}, {ask_k_nearest, {State#state.uid, node()}, Ref}) end, Start_point),
    Nearest = find_nodes_iter(Target, Seen, Start_point, Ref, State#state.k),
    self() ! {find_nodes_closed, Ref, Nearest},
    { noreply, State };



handle_cast({find_nodes_receive, Nearest, Ref}, State) ->
    io:format("SENDING to ~p ~p~n", [node(), self()]),
    self() ! {find_nodes_upd, Nearest, Ref},
    { noreply, State }.


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
