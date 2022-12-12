#!/usr/bin/env bash

source "$NCTL/sh/utils/main.sh"
source "$NCTL/sh/assets/setup_shared.sh"

# ----------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------

#######################################
# Sets network directories.
# Arguments:
#   Count of nodes to setup (default=5).
#   Version of protocol to which system is being upgraded.
#######################################
function _set_directories()
{
    log "... setting directories"

    local NODE_ID=${1}
    local PROTOCOL_VERSION=${2}

    mkdir -p "$(get_path_to_node_bin $NODE_ID)/$PROTOCOL_VERSION"
    mkdir -p "$(get_path_to_node_config $NODE_ID)/$PROTOCOL_VERSION"
}

#######################################
# Sets network binaries.
# Arguments:
#   Version of protocol being run.
#   Count of nodes to setup (default=5).
#   Path to casper-client binary.
#   Path to casper-node binary.
#   Path to casper-node-launcher binary.
#   Path to folder containing wasm binaries.
#######################################
function _setup_asset_binaries()
{
    log "... setting binaries"

    local PROTOCOL_VERSION=${1}
    local NODE_ID=${2}
    local PATH_TO_CLIENT=${3}
    local PATH_TO_NODE=${4}
    local PATH_TO_NODE_LAUNCHER=${5}
    local PATH_TO_WASM=${6}

    local PATH_TO_BIN
    local CONTRACT

    # Set node binaries.
    PATH_TO_BIN="$(get_path_to_node_bin "$NODE_ID")"
    if [ ! -f "$PATH_TO_BIN/casper-node-launcher" ]; then
        cp "$PATH_TO_NODE_LAUNCHER" "$PATH_TO_BIN"
    fi
    cp "$PATH_TO_NODE" "$PATH_TO_BIN/$PROTOCOL_VERSION"

    # Set client-side binary.
    PATH_TO_BIN="$(get_path_to_net)/bin"
    cp "$PATH_TO_CLIENT" "$PATH_TO_BIN"

    # Set client-side auction contracts;
    for CONTRACT in "${NCTL_CONTRACTS_CLIENT_AUCTION[@]}"
    do
        if [ -f "$PATH_TO_WASM/$CONTRACT" ]; then
            cp "$PATH_TO_WASM/$CONTRACT" \
               "$PATH_TO_BIN/auction"
        fi
    done

    # Set client-side shared contracts;
    for CONTRACT in "${NCTL_CONTRACTS_CLIENT_SHARED[@]}"
    do
        if [ -f "$PATH_TO_WASM/$CONTRACT" ]; then
            cp "$PATH_TO_WASM/$CONTRACT" \
            "$PATH_TO_BIN/shared"
        fi
    done

    # Set client-side transfer contracts;
    for CONTRACT in "${NCTL_CONTRACTS_CLIENT_TRANSFERS[@]}"
    do
        if [ -f "$PATH_TO_WASM/$CONTRACT" ]; then
            cp "$PATH_TO_WASM/$CONTRACT" \
            "$PATH_TO_BIN/transfers"
        fi
    done
}

#######################################
# Sets network chainspec.
# Arguments:
#   Count of nodes to setup (default=5).
#   Point (timestamp | era-id) when chainspec is considered live.
#   Delay in seconds to apply to genesis timestamp.
#   Path to chainspec template file.
#   Flag indicating whether chainspec pertains to genesis.
#######################################
function _setup_asset_chainspec()
{
    log "... setting chainspec.toml"

    local PROTOCOL_VERSION=${1}
    local ACTIVATION_POINT=${2}
    local PATH_TO_CHAINSPEC_TEMPLATE=${3}
    local IS_GENESIS=${4}
    local PATH_TO_CHAINSPEC
    local SCRIPT
    local COUNT_NODES

    # Shouldnt matter, maybe, idk ?, blame Tom if this causes an issue :)
    COUNT_NODES='100'

    # Set file.
    PATH_TO_CHAINSPEC="$(get_path_to_net)/chainspec/chainspec.toml"
    cp "$PATH_TO_CHAINSPEC_TEMPLATE" "$PATH_TO_CHAINSPEC"

    # Using sed because toml.dump was adding quotes around the true
    # which caused issues.
    sed -i 's/hard_reset = false/hard_reset = true/g' "$PATH_TO_CHAINSPEC"

    # Set contents.
    if [ "$IS_GENESIS" == true ]; then
        SCRIPT=(
            "import toml;"
            "cfg=toml.load('$PATH_TO_CHAINSPEC');"
            "cfg['protocol']['activation_point']='$ACTIVATION_POINT';"
            "cfg['protocol']['version']='$PROTOCOL_VERSION';"
            "cfg['network']['name']='$(get_chain_name)';"
            "cfg['core']['validator_slots']=$COUNT_NODES;"
            "toml.dump(cfg, open('$PATH_TO_CHAINSPEC', 'w'));"
        )
    else
        SCRIPT=(
            "import toml;"
            "cfg=toml.load('$PATH_TO_CHAINSPEC');"
            "cfg['protocol']['activation_point']=$ACTIVATION_POINT;"
            "cfg['protocol']['version']='$PROTOCOL_VERSION';"
            "cfg['network']['name']='$(get_chain_name)';"
            "cfg['core']['validator_slots']=$COUNT_NODES;"
            "toml.dump(cfg, open('$PATH_TO_CHAINSPEC', 'w'));"
        )
    fi

    python3 -c "${SCRIPT[*]}"
}

#######################################
# Sets node configuration files.
# Arguments:
#   Count of nodes to setup (default=5).
#   Version of protocol being ran.
#   Path to node configuration template file.
#   Flag indicating whether chainspec pertains to genesis.
#######################################
function _setup_asset_node_configs()
{
    log "... setting node configs"

    local NODE_ID=${1}
    local PROTOCOL_VERSION=${2}
    local PATH_TO_TEMPLATE=${3}
    local IS_GENESIS=${4}

    local PATH_TO_NET
    local PATH_TO_CONFIG
    local PATH_TO_CONFIG_FILE
    local SPECULATIVE_EXEC_ADDR
    local SCRIPT

    PATH_TO_NET="$(get_path_to_net)"

    # Set paths to node's config.
    PATH_TO_CONFIG="$(get_path_to_node "$NODE_ID")/config/$PROTOCOL_VERSION"
    PATH_TO_CONFIG_FILE="$PATH_TO_CONFIG/config.toml"

    # Set node configuration.
    if [ "$IS_GENESIS" == true ]; then
        cp "$PATH_TO_NET/chainspec/accounts.toml" "$PATH_TO_CONFIG"
    fi
    cp "$PATH_TO_NET/chainspec/chainspec.toml" "$PATH_TO_CONFIG"
    cp "$PATH_TO_TEMPLATE" "$PATH_TO_CONFIG_FILE"

    SPECULATIVE_EXEC_ADDR=$(grep 'speculative_execution_address' $PATH_TO_CONFIG_FILE || true)

    # Set node configuration settings.
    SCRIPT=(
        "import toml;"
        "cfg=toml.load('$PATH_TO_CONFIG_FILE');"
        "cfg['consensus']['secret_key_path']='../../keys/secret_key.pem';"
        "cfg['logging']['format']='$NCTL_NODE_LOG_FORMAT';"
        "cfg['network']['bind_address']='$(get_network_bind_address "$NODE_ID")';"
        "cfg['network']['known_addresses']=[$(get_network_known_addresses "$NODE_ID")];"
        "cfg['storage']['path']='../../storage';"
        "cfg['rest_server']['address']='0.0.0.0:$(get_node_port_rest "$NODE_ID")';"
        "cfg['rpc_server']['address']='0.0.0.0:$(get_node_port_rpc "$NODE_ID")';"
        "cfg['event_stream_server']['address']='0.0.0.0:$(get_node_port_sse "$NODE_ID")';"
    )

    if [ ! -z "$SPECULATIVE_EXEC_ADDR" ]; then
        SCRIPT+=(
            "cfg['rpc_server']['speculative_execution_address']='0.0.0.0:$(get_node_port_speculative_exec "$NODE_ID")';"
        )
    fi

    SCRIPT+=(
        "toml.dump(cfg, open('$PATH_TO_CONFIG_FILE', 'w'));"
    )

    python3 -c "${SCRIPT[*]}"

    # Do workarounds.
    # N.B. - these are temporary & come into scope when testing against protocol versions
    #        that have conflicting node configuration schemas.
    _setup_asset_node_config_workaround_1 "$NODE_ID" "$PATH_TO_CONFIG_FILE"

    # unit_hashes_folder was removed in version 1.4.2
    if [ "$(echo $PROTOCOL_VERSION | tr -d '_')" -ge "142" ]; then
        sed -i '/unit_hashes_folder/d' "$PATH_TO_CONFIG_FILE"
    fi
}

#######################################
# Sets node configuration file workaround related to 'unit_hashes_folder' setting change.
# Arguments:
#   Node ordinal identifier.
#   Path to folder containing staged config files.
#######################################
function _setup_asset_node_config_workaround_1()
{
    local NODE_ID=${1}
    local PATH_TO_CONFIG_FILE=${2}
    local HAS_HIGHWAY
    local SCRIPT

    HAS_HIGHWAY=$(grep -R "consensus.highway" "$PATH_TO_CONFIG_FILE" || true)
    if [ "$HAS_HIGHWAY" != "" ]; then
        SCRIPT=(
            "import toml;"
            "cfg=toml.load('$PATH_TO_CONFIG_FILE');"
            "cfg['consensus']['highway']['unit_hashes_folder']='../../storage-consensus';"
            "toml.dump(cfg, open('$PATH_TO_CONFIG_FILE', 'w'));"
        )
    else
        SCRIPT=(
            "import toml;"
            "cfg=toml.load('$PATH_TO_CONFIG_FILE');"
            "cfg['consensus']['unit_hashes_folder']='../../storage-consensus';"
            "toml.dump(cfg, open('$PATH_TO_CONFIG_FILE', 'w'));"
        )
    fi

    python3 -c "${SCRIPT[*]}"
}

function _validators_string()
{
    local IDX
    local COUNT_NODES_AT_GENESIS=$(get_count_of_genesis_nodes)
    local PATH_TO_NET

    local VALIDATORS

    PATH_TO_NET="$(get_path_to_net)"

    for IDX in $(seq 1 "$COUNT_NODES_AT_GENESIS")
    do
        VALIDATORS+="--validator $(cat "$PATH_TO_NET/nodes/node-$IDX/keys/public_key_hex"),$(get_node_pos_stake_weight "$COUNT_NODES_AT_GENESIS" "$IDX") "
    done

    echo $VALIDATORS
}

function _setup_asset_global_state_toml() {
    log "... setting node global_state.toml"

    local NODE_ID=${1}
    local TARGET_PROTOCOL_VERSION
    local GLOBAL_STATE_OUTPUT
    local GLOBAL_STATE_VALIDATOR_OUTPUT
    local PATH_TO_NET="$(get_path_to_net)"
    local GLOBAL_STATE_UPDATE_TOOL_MINOR_VERSION
    local STATE_ROOT_HASH
    local PRE_14
    local DATA_LMDB_PATH

    # Check version of the global state update tool. This is not a proper semver check, for simplicity, we rely on the minor part only.
    # 0.3 marks the transition to 1.5 fast sync node and supports the "validators" command.
    GLOBAL_STATE_UPDATE_TOOL_MINOR_VERSION=$("$NCTL_CASPER_HOME"/target/"$NCTL_COMPILE_TARGET"/global-state-update-gen \
        --version | grep -oE '[^ ]+$' | cut -c3-3)
    if [ "$GLOBAL_STATE_UPDATE_TOOL_MINOR_VERSION" -lt "3" ]; then
        log "ERROR :: Global State Update Generator must be version 0.3 or greater (found version 0.$GLOBAL_STATE_UPDATE_TOOL_MINOR_VERSION)"
        exit 1
    fi

    pushd "$(get_path_to_stages)/stage-1/"
    local STAGE_1_PRE_VERSION=$(find ./* -maxdepth 0 -type d | awk -F'/' '{ print $2 }' | tr -d '_' | sort | head -n 1)
    popd
    pushd "$(get_path_to_stages)/stage-1/"
    local TARGET_PROTOCOL_VERSION=$(find ./* -maxdepth 0 -type d | awk -F'/' '{ print $2 }' | sort | tail -n 1)
    local STAGE_1_POST_VERSION="$(echo $TARGET_PROTOCOL_VERSION | tr -d '_')"
    popd

    log "... processing upgrade from $STAGE_1_PRE_VERSION to $STAGE_1_POST_VERSION"
    STAGE_1_PRE_VERSION_LEN=`echo $STAGE_1_PRE_VERSION | wc -c`
    STAGE_1_POST_VERSION_LEN=`echo $STAGE_1_POST_VERSION | wc -c`

    if [ "$STAGE_1_PRE_VERSION_LEN" -ne "4" ] || [ "$STAGE_1_POST_VERSION_LEN" -ne "4" ]; then
        log "ERROR :: Node version segments must be single digit (eg. 1.4.5). Versions like 1.4.12 are not supported. This is only a limitation of this test script - for IRL upgrades any version should work"
    fi

   if [ "$STAGE_1_PRE_VERSION" -lt "140" ]; then
        log "... upgrading from pre 1.4.0 version"
        PRE_14=1
    else
        log "... upgrading from version 1.4.0 or later, no 'global_state.toml' file needed"
        PRE_14=0
    fi

    if [ "$PRE_14" -eq "1" ]; then
	    STORAGE_PATH="$PATH_TO_NET/nodes/node-$NODE_ID/storage"
        DATA_LMDB_PATH="$STORAGE_PATH/data.lmdb"
        log "... path to DB: $DATA_LMDB_PATH"

	    VALIDATOR_SETUP_STRING=$(validators_string)

        STATE_ROOT_HASH=$(nctl-view-chain-state-root-hash node=$NODE_ID | awk '{ print $12 }' | tr '[:upper:]' '[:lower:]')
        log "... state root hash for node $IDX: $STATE_ROOT_HASH"
        if [ -f $DATA_LMDB_PATH ]; then
                GLOBAL_STATE_OUTPUT=$("$NCTL_CASPER_HOME"/target/"$NCTL_COMPILE_TARGET"/global-state-update-gen \
                        migrate-into-system-contract-registry -s $STATE_ROOT_HASH -d "$PATH_TO_NET"/nodes/node-"$NODE_ID"/storage)

                GLOBAL_STATE_VALIDATOR_OUTPUT=$("$NCTL_CASPER_HOME"/target/"$NCTL_COMPILE_TARGET"/global-state-update-gen \
                        change-validators $VALIDATOR_SETUP_STRING -s $STATE_ROOT_HASH -d "$PATH_TO_NET"/nodes/node-"$NODE_ID"/storage) 
        else
                GLOBAL_STATE_OUTPUT=$("$NCTL_CASPER_HOME"/target/"$NCTL_COMPILE_TARGET"/global-state-update-gen \
                        migrate-into-system-contract-registry -s $STATE_ROOT_HASH -d "$PATH_TO_NET"/nodes/node-1/storage)

                GLOBAL_STATE_VALIDATOR_OUTPUT=$("$NCTL_CASPER_HOME"/target/"$NCTL_COMPILE_TARGET"/global-state-update-gen \
                        change-validators $VALIDATOR_SETUP_STRING -s $STATE_ROOT_HASH -d "$PATH_TO_NET"/nodes/node-1/storage)
        fi

        echo "$GLOBAL_STATE_VALIDATOR_OUTPUT" > "$PATH_TO_NET/nodes/node-$NODE_ID/config/$TARGET_PROTOCOL_VERSION/global_state.toml"
        echo "$GLOBAL_STATE_OUTPUT" >> "$PATH_TO_NET/nodes/node-$NODE_ID/config/$TARGET_PROTOCOL_VERSION/global_state.toml"
    fi
}

#######################################
# Returns next version to which protocol will be upgraded.
# Arguments:
#   Path to folder containing staged files.
#######################################
function _get_protocol_version_of_next_upgrade()
{
    local PATH_TO_STAGE=${1}
    local NODE_ID=${2}
    local IFS='_'
    local PROTOCOL_VERSION
    local PATH_TO_NX_BIN
    local SEMVAR_CURRENT
    local SEMVAR_NEXT

    PATH_TO_NX_BIN="$(get_path_to_net)/nodes/node-$NODE_ID/bin"

    # Set semvar of current version.
    pushd "$PATH_TO_NX_BIN" || exit
    read -ra SEMVAR_CURRENT <<< "$(ls -td -- * | head -n 1)"
    popd || exit

    # Iterate staged bin directories and return first whose semvar > current.
    for FHANDLE in "$PATH_TO_STAGE/"*; do
        if [ -d "$FHANDLE" ]; then
            PROTOCOL_VERSION=$(basename "$FHANDLE")
            if [ ! -d "$PATH_TO_NX_BIN/$PROTOCOL_VERSION" ]; then
                read -ra SEMVAR_NEXT <<< "$PROTOCOL_VERSION"
                if [ "${SEMVAR_NEXT[0]}" -gt "${SEMVAR_CURRENT[0]}" ] || \
                   [ "${SEMVAR_NEXT[1]}" -gt "${SEMVAR_CURRENT[1]}" ] || \
                   [ "${SEMVAR_NEXT[2]}" -gt "${SEMVAR_CURRENT[2]}" ]; then
                    echo "$PROTOCOL_VERSION"
                    break
                fi
            fi
        fi
    done
}

#######################################
# Moves upgrade assets into location.
#######################################
function _main()
{
    local STAGE_ID=${1}
    local ACTIVATION_POINT=${2}
    local VERBOSE=${3}
    local NODE_ID=${4}
    local CHAINSPEC_PATH=${5}
    local CONFIG_PATH=${6}
    local PATH_TO_STAGE
    local PROTOCOL_VERSION

    PATH_TO_STAGE="$NCTL/stages/stage-$STAGE_ID"
    PROTOCOL_VERSION=$(_get_protocol_version_of_next_upgrade "$PATH_TO_STAGE" "$NODE_ID")

    if [ -z "$CHAINSPEC_PATH" ]; then
        CHAINSPEC_PATH="$PATH_TO_STAGE/$PROTOCOL_VERSION/chainspec.toml"
    fi

    if [ -z "$CONFIG_PATH" ]; then
        CONFIG_PATH="$PATH_TO_STAGE/$PROTOCOL_VERSION/config.toml"
    fi

    if [ "$PROTOCOL_VERSION" != "" ]; then
        if [ "$VERBOSE" == true ]; then
            log "stage $STAGE_ID :: upgrade assets -> $PROTOCOL_VERSION @ era $ACTIVATION_POINT"
        fi
        _set_directories "$NODE_ID" \
                         "$PROTOCOL_VERSION"
        _setup_asset_binaries "$PROTOCOL_VERSION" \
                             "$NODE_ID" \
                             "$PATH_TO_STAGE/$PROTOCOL_VERSION/casper-client" \
                             "$PATH_TO_STAGE/$PROTOCOL_VERSION/casper-node" \
                             "$PATH_TO_STAGE/$PROTOCOL_VERSION/casper-node-launcher" \
                             "$PATH_TO_STAGE/$PROTOCOL_VERSION"
        _setup_asset_chainspec "$(get_protocol_version_for_chainspec "$PROTOCOL_VERSION")" \
                              "$ACTIVATION_POINT" \
                              "$CHAINSPEC_PATH" \
                              false
        _setup_asset_node_configs "$NODE_ID" \
                                 "$PROTOCOL_VERSION" \
                                 "$CONFIG_PATH" \
                                 false
        if [ "$(echo $PROTOCOL_VERSION | tr -d '_')" -ge "140" ]; then
            _setup_asset_global_state_toml "$NODE_ID" \
                                          "$PROTOCOL_VERSION"
        fi
        sleep 1.0
    else
        log "ATTENTION :: no more staged upgrades to rollout !!!"
    fi
}

# ----------------------------------------------------------------
# ENTRY POINT
# ----------------------------------------------------------------

unset ACTIVATION_POINT
unset NET_ID
unset STAGE_ID
unset VERBOSE
unset NODE_ID
unset CHAINSPEC_PATH
unset CONFIG_PATH

for ARGUMENT in "$@"
do
    KEY=$(echo "$ARGUMENT" | cut -f1 -d=)
    VALUE=$(echo "$ARGUMENT" | cut -f2 -d=)
    case "$KEY" in
        era) ACTIVATION_POINT=${VALUE} ;;
        net) NET_ID=${VALUE} ;;
        stage) STAGE_ID=${VALUE} ;;
        verbose) VERBOSE=${VALUE} ;;
        node) NODE_ID=${VALUE} ;;
        chainspec_path) CHAINSPEC_PATH=${VALUE} ;;
        config_path) CONFIG_PATH=${VALUE} ;;
        *)
    esac
done

export NET_ID=${NET_ID:-1}
ACTIVATION_POINT="${ACTIVATION_POINT:-$(get_chain_era)}"
if [ "$ACTIVATION_POINT" == "N/A" ]; then
    ACTIVATION_POINT=0
fi

_main "${STAGE_ID:-1}" \
      $((ACTIVATION_POINT + NCTL_DEFAULT_ERA_ACTIVATION_OFFSET)) \
      "${VERBOSE:-true}" \
      "${NODE_ID}" \
      "${CHAINSPEC_PATH}" \
      "${CONFIG_PATH}"
