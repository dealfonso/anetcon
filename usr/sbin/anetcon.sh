#!/bin/bash
#
#    Copyright 2024, Carlos A. <https://github.com/dealfonso>
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

function usage {
        cat <<EOF

Usage: $0 [options]

Options:
  -h, --help            Show this help message and exit
  -V, --version         Prints the version of the script and exit
  -v, --verbose         Enable debug mode
  -l, --log-file        File in which the log will appear (appart from stdout)
  -p, --period          Monitorization period to check if the iptables routes have been modified
  -n, --namespace       Space separated list of id routers to be monitorized (id can be obtained from openstack router list)
  -c, --config-file     Configuration file

This script is intended to monitor the iptables rules of a router in OpenStack. 

EOF
}

#
# Default values for the configuration files
#

# Version of this script
VERSION=1.0.0
# DEBUG: anything different than empty value sets the debug mode
DEBUG=
# Space separated list of id routers to be monitorized (id can be obtained from openstack router list)
NAMESPACES=( default )
# Monitorization period to check if the iptables routes have been modified
PERIOD=60
# List of networks to be monitorized for each router (the syntax is "<router id>" "<space separated list of network using cidr notation>")
NETS=( )
# File in which the log will appear (appart from stdout)
LOGFILE=/var/log/anetcon/anetcon.log
# Configuration file
CONFIG_FILE=/etc/anetcon.conf
# Chain in which to join anetcon (POSTROUTING should be fine in most cases)
CHAIN_TO_JOIN=POSTROUTING
# The content of the iptables from the router that is being analized
IPTABLES_NAMESPACE=( )
# The networks that should be monitorized for the router that is being analized
EXPECTED_NETS=( )
# The current namespace
CURRENT_NS=
CURRENT_NS_LOGHASH=
# The name of the chain for anetcon
CHAIN_NAME=anetcon
# Prefix for the log messages
LOG_PREFIX="[ANETCON]"
LOG_PREFIX_DNAT="[D]"
LOG_PREFIX_OTHER="[X]"
# Whether to include a hash of the namespace in the log messages so each namespace can be identified
#  (*) true: include the hash; <any other value>: do not include the hash
LOG_NAMESPACE_HASH=true
# File to store the hash of the namespaces to ease the identification of the logs
NAMESPACE_HASH_FILE=/var/lib/anetcon/namespace.hash

# Some utility functions

# Calculate the hash of a string with a given number of digits
function hash {
        local INPUT="$1"
        local DIGITS="${2:-8}"

        echo -n "$INPUT" | md5sum | cut -d " " -f 1 | cut -c 1-$DIGITS
}

function p_info {
        local TS=$(date +%F_%T | tr ':' '.')
        local OUTPUT="$@"
        echo "$TS - [info] - $OUTPUT"
        [ "$LOGFILE" != "" ] && echo "$TS - [info] - $OUTPUT" >> "$LOGFILE"
}

function p_error {
        local TS=$(date +%F_%T | tr ':' '.')
        local OUTPUT="$@"
        echo "$TS - [error] - $OUTPUT" >&2
        [ "$LOGFILE" != "" ] && echo "$TS - [error] - $OUTPUT" >> "$LOGFILE"
}

function p_debug {
        [ "$DEBUG" == "" ] && return 0
        local TS=$(date +%F_%T | tr ':' '.')
        local OUTPUT="$@"
        echo "$TS - [debug] - $OUTPUT" >&2
        [ "$LOGFILE" != "" ] && echo "$TS - [debug] - $OUTPUT" >> "$LOGFILE"
}

function p_debug_in {
        [ "$DEBUG" == "" ] && return 0
        local TS=$(date +%F_%T | tr ':' '.')
        local OUTPUT="$(cat - 2>&1)"
        [ "$OUTPUT" == "" ] && return 0
        echo "$TS - [debug] - $OUTPUT" >&2
        [ "$LOGFILE" != "" ] && echo "$TS - [debug] - $OUTPUT" >> "$LOGFILE"
}

function p_error_in {
        local TS=$(date +%F_%T | tr ':' '.')
        local OUTPUT="$(cat - 2>&1)"
        [ "$OUTPUT" == "" ] && return 0
        echo "$TS - [error] - $OUTPUT" >&2
        [ "$LOGFILE" != "" ] && echo "$TS - [error] - $OUTPUT" >> "$LOGFILE"
}

# First we'll look for a config file
ARGUMENTS=( "$@" )

function parse_arguments {
        for ((i=0; i<${#ARGUMENTS[@]}; i++)); do
                case "${ARGUMENTS[$i]}" in
                        -V|--version)
                                echo "$VERSION"
                                exit 0
                                ;;
                        -h|--help)
                                usage
                                exit 0
                                ;;
                        -v|--verbose)
                                DEBUG=true;;
                        -l|--log-file)
                                i=$((i+1))
                                LOGFILE="${ARGUMENTS[$i]}";;
                        -p|--period)
                                i=$((i+1))
                                PERIOD="${ARGUMENTS[$i]}";;
                        -n|--namespace)
                                i=$((i+1))
                                if [ "$CUSTOM_NAMESPACES" == "true" ]; then
                                        NAMESPACES+=( "${ARGUMENTS[$i]}" )
                                else
                                        NAMESPACES=( "${ARGUMENTS[$i]}" )
                                        CUSTOM_NAMESPACES=true
                                fi;;
                        -c|--config-file)
                                i=$((i+1))
                                CONFIG_FILE="${ARGUMENTS[$i]}";;
                        *)
                                echo "Unknown option ${ARGUMENTS[$i]}"
                                usage
                                exit 1
                                ;;        
                esac
        done
}

# we'll parse the arguments to get the configuration file
parse_arguments

# Load the configuration file (if exists)
if [ -e "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
                p_error "failed to load configuration"
                exit 1
        fi
else
        p_info "configuration file $CONFIG_FILE not found"
fi

# we'll parse the arguments again to give more priority to the command line arguments
parse_arguments

if ! [[ "$PERIOD" =~ ^[0-9]+$ ]]; then
        echo "Period must be a number"
        usage
        exit 1
fi

# Wrapper to iptables that allows to execute the command in the current namespace (if any)
function _iptables {
        if [ "$CURRENT_NS" == "" ]; then
                iptables -t nat "$@"
                return $?
        else
                ip netns exec $CURRENT_NS iptables -t nat "$@"
                return $?
        fi
}

# Load the iptables rules for one router, in IPTABLES_ROUTER var, and the EXPECTED_NETS for that router
function load_rules {
        local NAMESPACE="$1"
        p_debug "loading rules for namespace $NAMESPACE"

        if [ "$NAMESPACE" == "" ]; then
                NAMESPACE="default"
        fi

        if [ "$NAMESPACE" == "default" ]; then
                CURRENT_NS=""
                CURRENT_NS_LOGHASH=""
        else
                CURRENT_NS="$NAMESPACE"
                if [ "$LOG_NAMESPACE_HASH" == "true" ]; then
                        CURRENT_NS_LOGHASH="[$(hash "$NAMESPACE")]"
			if [ "$NAMESPACE_HASH_FILE" != "" ]; then
				local ORIGINAL_CONTENT="$(cat "$NAMESPACE_HASH_FILE" 2> /dev/null)"
				if [ $? -ne 0 ]; then
					p_error "failed to read hash file $NAMESPACE_HASH_FILE"
				else
					local NEW_CONTENT="$(echo "${ORIGINAL_CONTENT}
$NAMESPACE $CURRENT_NS_LOGHASH" | sort -u)"
					if [ "$ORIGINAL_CONTENT" != "$NEW_CONTENT" ]; then
						echo "$NEW_CONTENT" | sort -u > "$NAMESPACE_HASH_FILE"
						[ $? -ne 0 ] && p_error "failed to write hash file $NAMESPACE_HASH_FILE"
					fi
				fi
			fi
                else
                        CURRENT_NS_LOGHASH=""
                fi
        fi

        # Read the iptables rules
        local IPTABLES
        IPTABLES="$(_iptables -S 2> >(p_error_in))"

        if [ $? -ne 0 ]; then
                p_error "failed to load rules for namespace $NAMESPACE"
		IPTABLES_NAMESPACE=( )
                EXPECTED_NETS=( )
                return 1
        fi

        p_debug "rules for namespace $NAMESPACE successfully loaded"

        # Process the rules to get the ones that are related to anetcon
	IPTABLES_NAMESPACE=()
	local RULE
	while read RULE; do
		IPTABLES_NAMESPACE+=("$RULE")
	done <<< "$(echo "$IPTABLES" | grep " $CHAIN_NAME")"
        EXPECTED_NETS=( $(get_nets "$NAMESPACE") )
        return 0
}

# Obtains the list of networks to be monitorized for one namespace
function get_nets {
        local READNETS= VALIDNETS=
        local NAMESPACE="$1"

        for N in "${NETS[@]}"; do
                if [ "$READNETS" != "" ]; then
                        p_debug "found networks $N to monitor for namespace $NAMESPACE"
                        VALIDNETS="$N"
                        break
                fi
                if [ "$N" == "$NAMESPACE" ]; then
                        READNETS=1
                fi
        done
        echo "$VALIDNETS"
}

# Deletes the iptables rules associated to one router (this funcion relies on a previous call to load_rules)
function wipe_rules {
        p_debug "wiping rules for namespace $CURRENT_NS"

        # Remove the jumps to our rules
        while _iptables -D "$CHAIN_TO_JOIN" -j "$CHAIN_NAME" 2> /dev/null; do
                true
        done

        _iptables -F "$CHAIN_NAME"
        _iptables -X "$CHAIN_NAME"
}

# Sets the iptables to start logging the start of new connections (this function relies on a previous call to load_rules)
function create_rules {
        wipe_rules

        p_info "creating rules for namespace $CURRENT_NS"

        local SOURCE=( )
        local S
        local NET

        if ((${#EXPECTED_NETS[@]} > 0)); then
                for NET in "${EXPECTED_NETS[@]}"; do
                        SOURCE+=( "-s $NET" )
                done
        else
                SOURCE=( "" )
        fi

        _iptables -N "$CHAIN_NAME"
        _iptables -I "$CHAIN_TO_JOIN" -j "$CHAIN_NAME"

        # Create the new rules
        _iptables -A "$CHAIN_NAME" -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "${LOG_PREFIX}${LOG_PREFIX_DNAT}${CURRENT_NS_LOGHASH} " 2> >(p_error_in)
        if [ $? -ne 0 ]; then
                return 1
        fi

        for S in "${SOURCE[@]}"; do
                _iptables -A "$CHAIN_NAME" $S -p tcp -m tcp -m state --state NEW  -m conntrack ! --ctstate DNAT  -j LOG --log-prefix "${LOG_PREFIX}${LOG_PREFIX_OTHER}${CURRENT_NS_LOGHASH} " 2> >(p_error_in)
                if [ $? -ne 0 ]; then
                        return 1
                fi
        done
        return 0
}

# Function that checks that the rules for one router have been properly set (and they have not been changed)
function check_rules {
        p_debug "checking rules for namespace $CURRENT_NS"

        local NET
        local EXPECTED_RULES=(
                "-N $CHAIN_NAME"
                "-A $CHAIN_TO_JOIN -j $CHAIN_NAME"
                '-A '"$CHAIN_NAME"' -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "'"${LOG_PREFIX}${LOG_PREFIX_DNAT}${CURRENT_NS_LOGHASH} "'"'
        )
        if ((${#EXPECTED_NETS[@]} > 0)); then
                for NET in "${EXPECTED_NETS[@]}"; do
                        EXPECTED_RULES+=('-A '"$CHAIN_NAME"' -s $NET -p tcp -m tcp -m state --state NEW -m conntrack ! --ctstate DNAT -j LOG --log-prefix "'"${LOG_PREFIX}${LOG_PREFIX_OTHER}${CURRENT_NS_LOGHASH} "'"')
                done
        else
                EXPECTED_RULES+=('-A '"$CHAIN_NAME"' -p tcp -m tcp -m state --state NEW -m conntrack ! --ctstate DNAT -j LOG --log-prefix "'"${LOG_PREFIX}${LOG_PREFIX_OTHER}${CURRENT_NS_LOGHASH} "'"')
        fi

        p_debug "expected rules for namespace $CURRENT_NS: ${EXPECTED_RULES[@]}"
        p_debug "actual rules: ${IPTABLES_NAMESPACE[@]}"

        local RULE E_RULE FOUND
        for RULE in "${EXPECTED_RULES[@]}"; do
		FOUND=false
		for EXISTING_RULE in "${IPTABLES_NAMESPACE[@]}"; do
			if [ "$RULE" == "$EXISTING_RULE" ]; then
				p_debug "rule $RULE found"
				FOUND=true
				break;
			fi
		done
		if [ "$FOUND" == "false" ]; then
			p_debug "rule $RULE not found"
			return 1
		fi
	done
        return 0
}

# Function that monitors that the routes for each router are fine. If not, the rules for that router are wiped an set back again.
function monitor_namespaces {
        local NAMESPACE
        for NAMESPACE in ${VALID_NAMESPACES[@]}; do
                p_debug "monitoring namespace $NAMESPACE"

                if ! load_rules "$NAMESPACE"; then
                        p_error "failed to load rules for namespace $NAMESPACE"
                        continue
                fi
                if ! check_rules; then
                        p_error "rules for namespace $CURRENT_NS have changed... updating"

                        create_rules
                        [ $? -ne 0 ] && p_error "failed to setup rules for namespace $NAMESPACE"
                fi
        done
}

# Function that removes any rule for any router (this is intended for finalizing the service)
function cleanup {
        local NAMESPACE
        for NAMESPACE in ${VALID_NAMESPACES[@]}; do
                p_info "cleaning up rules for namespace $NAMESPACE"
                if ! load_rules "$NAMESPACE"; then
                        p_error "failed to load rules for namespace $NAMESPACE"
                        continue
                fi
                wipe_rules
        done
}

# If the namespaces are set to discover, then we will discover the namespaces
function valid_namespaces {
        local NAMESPACE EXISTING_NAMESPACE
        local EXISTING_NAMESPACES=( $(ip netns | cut -d " " -f 1) )
        VALID_NAMESPACES=( )

        for NAMESPACE in "${NAMESPACES[@]}"; do
		if [ "$NAMESPACE" == "default" ]; then
			VALID_NAMESPACES+=( "default" )
		else
			for EXISTING_NAMESPACE in "${EXISTING_NAMESPACES[@]}"; do
        	        	VALID_NAMESPACES+=( $(echo "$EXISTING_NAMESPACE" | grep "$NAMESPACE") )
			done
		fi
        done
	p_debug "found namespaces ${VALID_NAMESPACES[@]}"
}

# In case that the application is finalized, call the cleanup function
trap cleanup EXIT

# Enable logging for all namespaces
echo 1 > /proc/sys/net/netfilter/nf_log_all_netns

# Start monitoring
while true; do
        valid_namespaces
        monitor_namespaces
	p_debug "sleeping $PERIOD"
        sleep $PERIOD
done