#!/usr/bin/env bash

#######################################
# Spins up a node using supervisord.
# Arguments:
#   Network ordinal identifier.
#   Node ordinal identifier.
#######################################
function do_node_start()
{
    local NODE_ID=${1}
    local NODE_PROCESS_NAME
    local PATH_TO_NODE_CONFIG
    local TRUSTED_HASH

    # Ensure daemon is up.
    do_supervisord_start

    # If non-genesis node then inject a trusted hash.
    if [ "$NODE_ID" -gt "$(get_count_of_genesis_nodes)" ]; then
        PATH_TO_NODE_CONFIG=$(get_path_to_net)/nodes/node-"$NODE_ID"/config/node-config.toml
        TRUSTED_HASH=$(get_chain_latest_block_hash)
        sed -i "s/#trusted_hash/trusted_hash/g" "$PATH_TO_NODE_CONFIG" > /dev/null 2>&1
        sed -i "s/^\(trusted_hash\) = .*/\1 = \'${TRUSTED_HASH}\'/" "$PATH_TO_NODE_CONFIG" > /dev/null 2>&1
        log "... trusted hash=$TRUSTED_HASH"
    fi

    # Signal to supervisorctl.
    NODE_PROCESS_NAME=$(get_process_name_of_node_in_group "$NODE_ID")
    supervisorctl -c "$(get_path_net_supervisord_cfg)" start "$NODE_PROCESS_NAME"  > /dev/null 2>&1
}

#######################################
# Spins up all nodes using supervisord.
# Arguments:
#   Network ordinal identifier.
#   Count of nodes within network.
#   Count of bootstraps within network.
#######################################
function do_node_start_all()
{
    # Step 1: start bootstraps.
    log "... starting genesis bootstraps"
    do_node_start_group "$NCTL_PROCESS_GROUP_1"
    sleep 1.0

    # Step 2: start non-bootstraps.
    log "... starting genesis non-bootstraps"
    do_node_start_group "$NCTL_PROCESS_GROUP_2"
}

#######################################
# Spins up a node using supervisord.
# Arguments:
#   Network ordinal identifier.
#   Node ordinal identifier.
#######################################
function do_node_start_group()
{
    local GROUP_ID=${1}

    # Ensure daemon is up.
    do_supervisord_start

    # Signal to supervisorctl.
    supervisorctl -c "$(get_path_net_supervisord_cfg)" start "$GROUP_ID":*  > /dev/null 2>&1
}

#######################################
# Renders to stdout status of a node running under supervisord.
# Arguments:
#   Node ordinal identifier.
#######################################
function do_node_status()
{
    local NODE_ID=${1}
    local NODE_PROCESS_NAME
    
    NODE_PROCESS_NAME=$(get_process_name_of_node_in_group "$NODE_ID")

    # Ensure daemon is up.
    do_supervisord_start

    # Signal to supervisorctl.
    supervisorctl -c "$(get_path_net_supervisord_cfg)" status "$NODE_PROCESS_NAME"
}

#######################################
# Renders to stdout status of all nodes running under supervisord.
# Arguments:
#   Network ordinal identifier.
#######################################
function do_node_status_all()
{
    # Ensure daemon is up.
    do_supervisord_start

    # Signal to supervisorctl.
    supervisorctl -c "$(get_path_net_supervisord_cfg)" status all
}

#######################################
# Stops a node running via supervisord.
# Arguments:
#   Network ordinal identifier.
#   Node ordinal identifier.
#######################################
function do_node_stop()
{
    local NODE_ID=${1}
    local NODE_PROCESS_NAME
    
    # Ensure daemon is up.
    do_supervisord_start
    
    # Signal to supervisorctl.
    NODE_PROCESS_NAME=$(get_process_name_of_node_in_group "$NODE_ID")
    supervisorctl -c "$(get_path_net_supervisord_cfg)" stop "$NODE_PROCESS_NAME"  > /dev/null 2>&1
}

#######################################
# Stops all nodes running via supervisord.
#######################################
function do_node_stop_all()
{
    # Ensure daemon is up.
    do_supervisord_start
    
    # Signal to supervisorctl.
    supervisorctl -c "$(get_path_net_supervisord_cfg)" stop all  > /dev/null 2>&1
}

#######################################
# Starts supervisord (if necessary).
# Arguments:
#   Network ordinal identifier.
#######################################
function do_supervisord_start()
{
    # If sock file not found then start daemon.
    if [ ! -e "$(get_path_net_supervisord_sock)" ]; then
        supervisord -c "$(get_path_net_supervisord_cfg)"
        sleep 2.0
    fi
}

#######################################
# Kills supervisord (if necessary).
# Arguments:
#   Network ordinal identifier.
#######################################
function do_supervisord_kill()
{
    # If sock file exists then stop daemon.
    if [ -e "$(get_path_net_supervisord_sock)" ]; then
        supervisorctl -c "$(get_path_net_supervisord_cfg)" stop all &>/dev/null
        supervisorctl -c "$(get_path_net_supervisord_cfg)" shutdown &>/dev/null
    fi
}
