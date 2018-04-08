-module(dht_buckets).
-include("dht.hrl").

-export([update/2, find_k_nearest_self/1, find_k_nearest/3]).

% find the k nearest State from our curent node
find_k_nearest_self(State) ->
    find_k_nearest_self(State, 0, State#state.k, []).

find_k_nearest_self(_State, _I, 0, Acc) ->
    Acc;

find_k_nearest_self(_State, I, _N, Acc) when I >= 160 ->
    Acc;

find_k_nearest_self(State, I, N, Acc) ->
    Bucket = array:get(I, State#state.buckets),
    find_k_nearest_self(State, I+1, N - length(Bucket), list:sublist(Bucket, N) ++ Acc).




% find the m nearest State from a given node
find_k_nearest(State, M, Node) ->
    find_k_nearest(State, 0, M, Node, []).

find_k_nearest(_State, I, _M, _Node, Acc) when I >= 160 ->
    Acc;

find_k_nearest(State, I, M, {Uid_Node, _} = Node, Acc) ->
    Bucket = array:get(I, State#state.buckets),
    Fun = fun ({U1, _}, {U2, _}) -> (U1 bxor Uid_Node) =< (U2 bxor Uid_Node) end,
    SBucket = list:sort(Fun, Bucket),
    find_k_nearest(State, I+1, M, Node, list:sublist(list:merge(Fun, Acc, SBucket), M)).




update(State, {Uid_new_node, _} = Node) ->
    D = dht_utils:distance(State#state.uid, Uid_new_node),
    I = find_power_two(D),
    New_bucket = update_bucket(State, array:get(I, State#state.buckets), Node),
    Buckets = array:set(I, New_bucket, State#state.buckets),
    State#state{buckets=Buckets}.



update_bucket(State, Bucket, New_node) ->
    case list:member(New_node, Bucket) of 
        true ->
            Bucket;
        false ->
            case length(Bucket) < State#state.k of  
                true -> 
                    [New_node | Bucket];
                false ->
                    [H | T] = Bucket,
                    case dht_server:ping(H) of
                        ok -> Bucket;
                        _ -> [New_node | T]
                    end
            end
    end.


%find i such as 2**i <= N <= 2**{i+1}
find_power_two(N) ->
    find_power_two(N, 0, 1).

find_power_two(N, I, C) when 2 * C > N ->
    I;

find_power_two(N, I, C) ->
    find_power_two(N, I+1, 2*C).
