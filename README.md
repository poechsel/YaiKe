# YaiKe

Yet another implementation of Kademlia in Erlang


## Build instructions:

To build, just type `make`

## How to use

Their is two ways to use this program

### Using `dht` application

You can use the application `dht` in order to launch and control one individual node.

In order to launch it, just type `application:start(dht).` in an erlang shell

Here is the full list of command:

- dht:store(Value) -> To store the value `Value` on the dht. Returns the `Hash` which acts as a key
- dht:pull(Hash) -> To retrieve the value associated to the key `Hash`
- dht:broadcast(Msg) -> To broadcast the message `Msg` through the dht
- dht:scatter(MsgList) -> To scatter `MsgList` through the dht
- dht:connect(Node) -> To connect to the node `Node`. You are responsible to make sure that your node and `Node` can interact with one other (ie there cookie is the same)
- dht:remove(Hash) -> To remove the value associated to the key `Hash`
- dht:stats() -> To view some stats about this current node
- dht:stop() -> To stop this current node


### Using the `client` script

The best way to use this dht is to use the `client` script. This is a small CLI script which allows to control several nodes at once.

To use it, first open an erlang shell with the same cookie as your other shells. Then: 

```
>> c(client).
>> client:start_link().
```

And your done!
You're free to use the following commands in order to interact with the network:

- client:deploy(NodeList) -> NodeList is a list of atom of nodes (ex: `['foo@...', 'bar@...']`), then the client will deploy a kademlia node on each of these nodes and link them together
- client:deploy_from_file(Filename) -> Same as the above one, but here `Filename` is the name of a file containing names of nodes (one per line)
- client:stats() -> output stats about the dht
- client:connect(Node, Other) -> connect node `Node` to node `Other`
- client:store(Value) -> Store the value `Value` on the dht. Returns its key
- client:pull(Hash) -> Returns `{found, value}` where value is associated to the key `Hash` if possible, otherwise `{notfound}`
- client:remove(Hash) -> Remove the value associated to the key `Hash`
- client:stop(Node) -> Stop the kademlia node from node `Node`
- client:broadcast(Msg) -> Broadcast `Msg` on all nodes
- client:scatter(MsgList) -> Scatter `MsgList` on all nodes
- client:spawn_agent(Node) -> Spawn a kademlia agent remotely on node `Node`





## Misc

This is a naive implementation of Kademlia. The routing table is the most naive one and is absolutely not optimized. Thus, several optimizations described in the original papers aren't implemented!
Nevertheless, this implementation has a naive key republishing and table refreshing mechanism. 
