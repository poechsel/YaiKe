-module(client).

-export([spawn_agent/1, get_archive/1, hello/0, send_code/1, uncompress_and_load/1]).
-behaviour(gen_server).
-export([handle_call/3, handle_cast/2, start_link/0, init/1]).



start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


get_archive(Folder) ->
    Files = filelib:wildcard( Folder ++ "/*" ),
    {ok, {_, Stream}} = zip:create("kamdelia.zip", Files, [memory]),
    Stream.

hello() ->
    io:format("hello~n").

send_code(Node) ->
    { Mod, Bin, File } = code:get_object_code(client),
    spawn(Node, code, load_binary, [Mod, File, Bin]).


uncompress_and_load(Stream) ->
    Path = "/tmp/kademlia_",
    io:format("~p~n",[Path]),
    zip:extract(Stream, [{cwd, Path}]),
    code:add_patha(Path ++ "/ebin/"),
    application:start(dht).

spawn_agent(Node) ->
    case net_adm:ping(Node) of
        pong -> 
            send_code(Node),
            Stream = get_archive("ebin/"),
            rpc:call(Node, ?MODULE, uncompress_and_load, [Stream]);
        pang -> io:format("Node not reachable~n")
    end.


init(_) ->
    {ok, {}}.

handle_call(_, _From, State) ->
    {reply, [], State}.

handle_cast(_, State) ->
    {noreply, [], State}.
