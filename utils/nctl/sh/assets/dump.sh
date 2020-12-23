#!/usr/bin/env bash

source $NCTL/sh/utils.sh

log "dumping transient assets ... please wait"

# Set paths.
PATH_TO_NET=$(get_path_to_net)
PATH_TO_DUMP=$(get_path_to_net_dump)

# Set dump directory.
if [ -d $PATH_TO_DUMP ]; then
    rm -rf $PATH_TO_DUMP
fi
mkdir -p $PATH_TO_DUMP

# Dump chainspec.
cp $PATH_TO_NET/chainspec/accounts.csv $PATH_TO_DUMP/accounts.csv
cp $PATH_TO_NET/chainspec/chainspec.toml $PATH_TO_DUMP

# Dump daemon.
if [ $NCTL_DAEMON_TYPE = "supervisord" ]; then
    cp $PATH_TO_NET/daemon/config/supervisord.conf $PATH_TO_DUMP/daemon.conf
    cp $PATH_TO_NET/daemon/logs/supervisord.log $PATH_TO_DUMP/daemon.log
fi

# Dump faucet.
cp $PATH_TO_NET/faucet/public_key_hex $PATH_TO_DUMP/faucet-public_key_hex
cp $PATH_TO_NET/faucet/public_key.pem $PATH_TO_DUMP/faucet-public_key.pem
cp $PATH_TO_NET/faucet/secret_key.pem $PATH_TO_DUMP/faucet-secret_key.pem

# Dump nodes.
for NODE_ID in $(seq 1 $(get_count_of_genesis_nodes))
do
    PATH_TO_NODE=$(get_path_to_node $NODE_ID)
    cp $PATH_TO_NODE/config/node-config.toml $PATH_TO_DUMP/node-$NODE_ID-config.toml
    cp $PATH_TO_NODE/keys/public_key_hex $PATH_TO_DUMP/node-$NODE_ID-public_key_hex
    cp $PATH_TO_NODE/keys/public_key.pem $PATH_TO_DUMP/node-$NODE_ID-public_key.pem
    cp $PATH_TO_NODE/keys/secret_key.pem $PATH_TO_DUMP/node-$NODE_ID-secret_key.pem
    cp $PATH_TO_NODE/logs/stderr.log $PATH_TO_DUMP/node-$NODE_ID-stderr.log
    cp $PATH_TO_NODE/logs/stdout.log $PATH_TO_DUMP/node-$NODE_ID-stdout.log
done

# Dump users.
for USER_ID in $(seq 1 $(get_count_of_users))
do
    PATH_TO_USER=$(get_path_to_user $USER_ID)
    cp $PATH_TO_USER/public_key_hex $PATH_TO_DUMP/user-$USER_ID-public_key_hex
    cp $PATH_TO_USER/public_key.pem $PATH_TO_DUMP/user-$USER_ID-public_key.pem
    cp $PATH_TO_USER/secret_key.pem $PATH_TO_DUMP/user-$USER_ID-secret_key.pem
done
