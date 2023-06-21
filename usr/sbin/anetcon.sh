#!/bin/bash

#
# Default values for the configuration files
#

# DEBUG: anything different than empty value sets the debug mode
DEBUG=
# Space separated list of id routers to be monitorized (id can be obtained from openstack router list)
ROUTERS=( default )
# Monitorization period to check if the iptables routes have been modified
PERIOD=60
# List of networks to be monitorized for each router (the syntax is "<router id>" "<space separated list of network using cidr notation>")
NETS=( )
# File in which the log will appear (appart from stdout)
LOGFILE=/var/log/anetcon/anetcon.log
# Chain in which to join anetcon (POSTROUTING should be fine in most cases)
CHAIN_TO_JOIN=POSTROUTING

# The content of the iptables from the router that is being analized
IPTABLES_ROUTER=
IPTABLES_LINKS=
# The networks that should be monitorized for the router that is being analized
EXPECTED_NETS=( )
# The current router that is being analized
ROUTER_ID=
ROUTER_NS=

# Some utility functions
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

if [ -e /etc/anetcon.conf ]; then
        . /etc/anetcon.conf
        if [ $? -ne 0 ]; then
                p_error "failed to load configuration"
        fi
fi

function _iptables {
        if [ "$ROUTER_ID" == "" ]; then
                iptables "$@"
                return $?
        else
                ip netns $ROUTER_NS exec iptables "$@"
                return $?
        fi
}

# Load the iptables rules for one router, in IPTABLES_ROUTER var, and the EXPECTED_NETS for that router
function load_rules {
        p_debug "loading rules for router $1"

        ROUTER_ID="$1"
        if [ "$ROUTER_ID" == "default" ]; then
                ROUTER_ID=""
                ROUTER_NS=""
        else
                ROUTER_NS="qrouter-$ROUTER_ID"
        fi
        # local IPTABLES="$(ip netns exec $ROUTER_NS iptables -t nat -S 2> /dev/null)"
        local IPTABLES
        IPTABLES="$(_iptables -t nat -S 2> >(p_error_in))"

        if [ $? -ne 0 ]; then
                p_error "failed to load rules for router $ROUTER_ID"

                IPTABLES_ROUTER=
                IPTABLES_LINKS=
                EXPECTED_NETS=( )
                return 1
        fi

        p_debug "rules for router $ROUTER_ID successfully loaded"
        IPTABLES_ROUTER="$(echo "$IPTABLES" | grep '^-A anetcon')"
        IPTABLES_LINKS="$(echo "$IPTABLES" | grep -- '-j anetcon')"
        EXPECTED_NETS=( $(get_nets) )
        return 0
}

# Obtains the list of networks to be monitorized for one router
function get_nets {
        local READNETS= VALIDNETS=
        local ROUTER="$ROUTER_ID"
        if [ "$ROUTER" == "" ]; then
                ROUTER="default"
        fi

        for N in "${NETS[@]}"; do
                if [ "$READNETS" != "" ]; then
                        p_debug "found networks $N to monitor in router $ROUTER"

                        VALIDNETS="$N"
                        break
                fi
                if [ "$N" == "$ROUTER" ]; then
                        READNETS=1
                fi
        done
        echo "$VALIDNETS"
}

# Deletes the iptables rules associated to one router (this funcion relies on a previous call to load_rules)
function wipe_rules {
        local RULE
        local CMD
        local RULES

        p_debug "wiping rules for router $ROUTER_ID"

        # Remove all rules for that router that link to our chain
        # * this could be replaced by the iptables -D table -j anetcon
        # RULES="$(echo "$IPTABLES_LINKS" | sed 's/^-A/-D/g')"
        # while read RULE; do
        #         if [ "$RULE" != "" ]; then
        #                 # CMD=( ip netns exec "$ROUTER_NS" iptables -t nat )
        #                 CMD=( _iptables -t nat )
        #                 while IFS= read -r -d ''; do
        #                         CMD+=("$REPLY")
        #                 done < <(xargs printf '%s\0' <<< "$RULE")
        #                 "${CMD[@]}" 2> >(p_error_in)
        #         fi
        # done <<< "$RULES"

        # Remove the jumps to our rules
        while _iptables -t nat -D "$CHAIN_TO_JOIN" -j anetcon 2> /dev/null; do
                true
        done

        _iptables -t nat -F anetcon
        _iptables -t nat -X anetcon
}

# Sets the iptables to start logging the start of new connections (this function relies on a previous call to load_rules)
function setup_rules {
        wipe_rules

        p_info "creating rules for router $ROUTER_ID"

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

        _iptables -t nat -N anetcon
        _iptables -t nat -I "$CHAIN_TO_JOIN" -j anetcon

        # Create the new rules
        # ip netns exec $ROUTER_NS iptables -t nat -I neutron-l3-agent-snat -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "[ANETCON] [FLOAT] " 2> /dev/null
        _iptables -t nat -A anetcon -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "[ANETCON] [FLOAT] " 2> >(p_error_in)
        if [ $? -ne 0 ]; then
                return 1
        fi

        for S in "${SOURCE[@]}"; do
                # ip netns exec $ROUTER_NS iptables -t nat -I neutron-l3-agent-snat $S -p tcp -m tcp -m state --state NEW  -m conntrack ! --ctstate DNAT  -j LOG --log-prefix "[ANETCON] [NAT] "
                _iptables -t nat -A anetcon $S -p tcp -m tcp -m state --state NEW  -m conntrack ! --ctstate DNAT  -j LOG --log-prefix "[ANETCON] [NAT] " 2> >(p_error_in)
                if [ $? -ne 0 ]; then
                        return 1
                fi
        done
        return 0
}

# Function that checks that the rules for one router have been properly set (and they have not been changed)
#       * at this point the rules are not inspected in depth; the only criteria is to have the appropriate amount of rules, depending on the number of networks to monitor
function check_rules {
        return 0
        local SOURCE=( )
        local S
        local NET

        p_debug "checking rules for router $ROUTER_ID"

        local NETCOUNT="${#EXPECTED_NETS[@]}"
        if ((NETCOUNT == 0)); then
                NETCOUNT=1
        fi

        local RULE_COUNT="$(echo "$IPTABLES_ROUTER" | wc -l)"
        local EXPECTED_RULES=$((1 + NETCOUNT))
        if ((RULE_COUNT!=EXPECTED_RULES)); then
                p_debug "number of rules for router $ROUTER_ID is not the expected"
                return 1
        fi
        return 0
}

# Function that monitors that the routes for each router are fine. If not, the rules for that router are wiped an set back again.
function monitor_routers {
        local ROUTER
        for ROUTER in ${ROUTERS[@]}; do
                p_debug "monitoring router $ROUTER"

                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                if ! check_rules; then
                        p_error "rules for router $ROUTER have changed... updating"

                        # wipe_rules
                        setup_rules
                        [ $? -ne 0 ] && p_error "failed to setup rules for router $ROUTER"
                fi
        done
}

# Function that removes any rule for any router (this is intended for finalizing the service)
function cleanup {
        local ROUTER
        for ROUTER in ${ROUTERS[@]}; do
                p_info "cleaning up rules for router $ROUTER"
                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                wipe_rules
        done
}

# Function that adds the rules for any router (this is intended for starting the service)
function setup {
        local ROUTER
        for ROUTER in ${ROUTERS[@]}; do
                p_info "setting up rules for router $ROUTER"
                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                # wipe_rules
                setup_rules
                [ $? -ne 0 ] && p_error "failed to setup rules for router $ROUTER"
        done
}

# In case that the application is finalized, call the cleanup function
trap cleanup EXIT

# Prepare the rules
setup

# Enable logging for all namespaces
echo 1 > /proc/sys/net/netfilter/nf_log_all_netns

# Start monitoring
while true; do
        monitor_routers
        sleep $PERIOD
done