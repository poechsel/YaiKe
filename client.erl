-module(client).

-export([spawn_agent/1, get_archive/1, send_code/1, uncompress_and_load/1, store/2, pull/2, remove/2, kill/1, deploy/1, deploy_from_file/1]).
-behaviour(gen_server).
-export([handle_call/3, handle_cast/2, start_link/0, init/1, handle_info/2, connect/2, stats/0]).



start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


get_archive(Folder) ->
    Files = filelib:wildcard( Folder ++ "/*" ),
    {ok, {_, Stream}} = zip:create("kamdelia.zip", Files, [memory]),
    Stream.

call_dht_function(Node, Fun, Args) ->
    case (rpc:call(Node, dht, Fun, Args)) of
        { badrpc, _ } ->
            io:format("No agent launched on node ~p~n", [Node]);
        R -> R
    end.


deploy(NodeList) ->
    lists:foreach(fun (Node) -> spawn_agent(Node) end, NodeList),
    case NodeList of 
        [H | T] ->
            lists:foreach(fun (Node) -> connect(Node, H) end, T), ok;
        _ -> ok
    end.

deploy_from_file(Filename) ->
    io:format("~p~n", [readlines(Filename)]),
    Lines = readlines(Filename),
    FL = lists:filter(fun (L) -> L /= <<>> end, Lines),
    deploy(lists:map(fun (L) -> binary_to_atom(L, utf8) end, FL)).

stats() ->
    gen_server:call(?MODULE, stats).

connect(Node, Other) ->
    io:format("Adding node ~p to the topology of ~p~n", [Other, Node]),
    call_dht_function(Node, connect, [Other]).

store(Node, Value) ->
    call_dht_function(Node, store, [Value]).

pull(Node, Hash) ->
    call_dht_function(Node, pull, [Hash]).

remove(Node, Hash) ->
    call_dht_function(Node, remove, [Hash]).

kill(Node) ->
    gen_server:call(?MODULE, {kill, Node}).

send_code(Node) ->
    { Mod, Bin, File } = code:get_object_code(client),
    spawn(Node, code, load_binary, [Mod, File, Bin]).


uncompress_and_load(Stream) ->
    Path = "/tmp/kademlia_",
    zip:extract(Stream, [{cwd, Path}]),
    code:add_patha(Path ++ "/ebin/"),
    application:start(dht).

spawn_agent(Node) ->
    io:format("Spawning an agent on node ~p~n", [Node]),
    gen_server:call(?MODULE, {spawn_agent, Node}).


init(_) ->
    {ok, sets:new()}.

handle_call({spawn_agent, Node}, _From, State) ->
    case net_adm:ping(Node) of
        pong -> 
            erlang:monitor_node(Node, true),
            send_code(Node),
            Stream = get_archive("ebin/"),
            rpc:call(Node, ?MODULE, uncompress_and_load, [Stream]),
            {reply, ok, sets:add_element(Node, State) };
        pang -> 
            {reply, unreachable, State}
    end;

handle_call({kill, Node}, _From, State) ->
    call_dht_function(Node, stop, []),
    NS = sets:del_element(Node, State),
    case sets:to_list(NS) of
        [ X | _ ] -> { reply, X, NS };
        _ -> { reply, nonodes, NS }
    end;

handle_call(stats, _From, State) ->
    L = sets:to_list(State),
    io:format("The dht has ~p nodes~n", [length(L)]),
    L2 = lists:map(fun (Node) -> call_dht_function(Node, stats, []) end, L),
    {NNodesavg, Lupdmin, Nemptavg, NStoredavg} = 
    lists:foldl(
           fun ({{NNodes, Lupd, Nempt}, NStored}, {A, B, C, D}) ->
                   {A+NNodes, min(Lupd, B), Nempt + C, NStored + D}
           end,
           {0, os:timestamp(), 0, 0},
           L2),
    io:format("   Each nodes store on average ~p values~n", [NStoredavg / length(L)]),
    io:format("   Each nodes knows of ~p other nodes on average~n", [NNodesavg / length(L)]),
    io:format("   Each routing tables has ~p non empty buckets (average)~n", [Nemptavg / length(L)]),
    io:format("   The time we updated the last routing bucket is ~p~n", [Lupdmin]),
    {reply, done, State};

handle_call(_, _From, State) ->
    {reply, [], State}.

handle_cast(_, State) ->
    {noreply, [], State}.

handle_info({nodedown, Node}, State) ->
    io:format("Node ~p has stopped working~n", [Node]),
    { noreply, sets:del_element(Node, State) }.

readlines(FileName) ->
    case file:read_file(FileName) of
        {ok, Data} -> binary:split(Data, [<<"\n">>], [global]);
        {error, _} -> io:format("file ~p doesn't exists", [FileName])
    end.
