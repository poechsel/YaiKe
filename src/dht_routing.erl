-module(dht_routing).
-include("dht.hrl").

-behavior(gen_server).

-export([update/1, find_k_nearest_self/1, find_k_nearest/2, debug/0]).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


%%% Client API
start_link(K, Alpha, Uid) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [K, Alpha, Uid], []).

init([K, Alpha, Uid]) -> 
    {ok, #routing{k=K, alpha=Alpha, uid=Uid}}.


debug() ->
    gen_server:call(?MODULE, debug).

% find the k nearest State from our curent node
find_k_nearest_self(State) ->
    find_k_nearest_self(State, 0, State#routing.k, []).

find_k_nearest_self(_State, _I, 0, Acc) ->
    Acc;

find_k_nearest_self(_State, I, _N, Acc) when I >= 160 ->
    Acc;

find_k_nearest_self(State, I, N, Acc) ->
    Bucket = array:get(I, State#routing.buckets),
    find_k_nearest_self(State, I+1, N - length(Bucket), lists:sublist(Bucket, N) ++ Acc).




% find the m nearest State from a given node
find_k_nearest(M, Node) ->
    gen_server:call(?MODULE, {find_k_nearest, M, Node}).

find_k_nearest(_State, I, _M, _Node, Acc) when I >= 160 ->
    Acc;

find_k_nearest(State, I, M, Uid_Node, Acc) ->
    Bucket = array:get(I, State#routing.buckets),
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Uid_Node) =< (U2 bxor Uid_Node) end,
    SBucket = lists:sort(Fun, Bucket),
    find_k_nearest(State, I+1, M, Uid_Node, lists:sublist(lists:merge(Fun, Acc, SBucket), M)).




update(Node) ->
    gen_server:cast(?MODULE, {update, Node}).



update_bucket(State, Bucket, New_node) ->
    case lists:member(New_node, Bucket) of 
        true ->
            Bucket;
        false ->
            case length(Bucket) < State#routing.k of  
                true -> 
                    [New_node | Bucket];
                false ->
                    [H | T] = Bucket,
                    case dht_server:ping(H) of
                        {ok, _} -> Bucket;
                        _ -> [New_node | T]
                    end
            end

    end.


handle_call({find_k_nearest, M, Node}, _From, State) ->
    N = find_k_nearest(State, 0, M, Node, []),
    { reply, N, State };

handle_call(debug, _From, State) ->
    io:format("BUCKETS ~p~n", [State#routing.buckets]),
    { reply, ok, State }.

handle_cast({update, {Uid_new_node, _} = Node}, State) ->
    D = dht_utils:distance(State#routing.uid, Uid_new_node),
    I = find_power_two(D),
    New_bucket = update_bucket(State, array:get(I, State#routing.buckets), Node),
    Buckets = array:set(I, New_bucket, State#routing.buckets),
    { noreply, State#routing{buckets=Buckets}}.

%find i such as 2**i <= N <= 2**{i+1}
find_power_two(N) ->
    find_power_two(N, 0, 1).

find_power_two(N, I, C) when 2 * C > N ->
    I;

find_power_two(N, I, C) ->
    find_power_two(N, I+1, 2*C).

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