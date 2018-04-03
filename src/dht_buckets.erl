-module(dht_buckets).
-include("dht.hrl").

-export([update/3, find_k_nearest/1]).

update(State, Uid_new_node, New_node) ->
    D = dht_utils:distance(State#state.uid, Uid_new_node),
    I = find_power_two(D),
    New_bucket = update_bucket(State, array:get(I, State#state.buckets), New_node),
    Buckets = array:set(I, New_bucket, State#state.buckets),
    State#state{buckets=Buckets}.


find_k_nearest(State) ->
    find_k_nearest(State, 0, State#state.alpha, []).

find_k_nearest(_State, _I, 0, Acc) ->
    Acc;

find_k_nearest(_State, I, _N, Acc) when I >= 160 ->
    Acc;

find_k_nearest(State, I, N, Acc) ->
    Bucket = array:get(I, State#state.buckets),
    find_k_nearest(State, I+1, N - length(Bucket), list:sublist(Bucket, N) ++ Acc).


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
