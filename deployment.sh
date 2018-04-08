#!/bin/bash

pids=()
erl -pa ebin -name a -eval "application:start(dht)" -noshell --setcookie a &
pids+=($!)
erl -pa ebin -name b -eval "application:start(dht)" -noshell --setcookie a &
pids+=($!)
erl -pa ebin -name c -eval "application:start(dht)" -noshell --setcookie a &
pids+=($!)
erl -pa ebin -name d -eval "application:start(dht)" -noshell --setcookie a &
pids+=($!)

read -n 1 -s -r -p "Press any key to continue"

echo "end";
for i in "${pids[@]}"
do
    kill -9 $i
done
