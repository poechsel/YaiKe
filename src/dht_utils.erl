-module(dht_utils).

-export([hash/1, distance/2]).

hash(Atom) when is_atom(Atom)->
    hash(atom_to_binary(Atom, utf8));

hash(Object) ->
    H = crypto:hash(sha, Object),
    binary_hash_to_integer(H).


binary_hash_to_integer(T) ->
    binary_hash_to_integer(T, 0).

binary_hash_to_integer(<<H, T/binary>>, Acc) ->
    binary_hash_to_integer(T, H + 256 * Acc);

binary_hash_to_integer(<<>>, Acc) -> 
    Acc.


distance(A, B) ->
    A bxor B.
