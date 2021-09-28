#!/bin/bash

DEBUG=
ROUTERS=( )
PERIOD=60
NETS=( )
LOGFILE=/var/log/anetcon/anetcon.log

# Las iptables del router que se esta analizando
IPTABLES_ROUTER=
EXPECTED_NETS=( )

function p_info {
        local TS=$(date +%F_%T | tr ':' '.')
        echo "$TS - [info] - $@" | tee -a "$LOGFILE"
}

function p_error {
        local TS=$(date +%F_%T | tr ':' '.')
        echo "$TS - [error] - $@" >&2 | cat - 2>&1 | tee -a "$LOGFILE"
}

function p_debug {
        [ "$DEBUG" == "" ] && return 0
        local TS=$(date +%F_%T | tr ':' '.')
        echo "$TS - [debug] - $@" >&2  | cat - 2>&1 | tee -a "$LOGFILE"
}

if [ -e /etc/anetcon.conf ]; then
        . /etc/anetcon.conf
        if [ $? -ne 0 ]; then
                p_error "failed to load configuration"
        fi
fi

# Carga las iptables de un router, para que esten listas para analizar
function load_rules {

        p_debug "loading rules for router $1"

        local NS="qrouter-$1"
        local IPTABLES="$(ip netns exec $NS iptables -t nat -S 2> /dev/null)"

        if [ $? -ne 0 ]; then
                p_error "failed to load rules for router $1"

                IPTABLES_ROUTER=
                EXPECTED_NETS=( )
                return 1
        fi

        p_debug "rules for router $1 successfully loaded"
        IPTABLES_ROUTER="$(echo "$IPTABLES" | grep '\[ANETCON\]')"
        EXPECTED_NETS=( $(get_nets "$ROUTER") )
        return 0
}

# Obtiene la lista de redes NAT que se quieren monitorizar para un router
function get_nets {
        local READNETS= ROUTER="$1" VALIDNETS=
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
# Borra las reglas del router que se esta analizando actualmente (debe haberse llamado antes a load_rules)
function wipe_rules {
        local NS="qrouter-$1"
        local RULE
        local CMD
        local RULES

        p_debug "wiping rules for router $1"

        # Remove all rules for that router (those loaded by load_rules)
        RULES="$(echo "$IPTABLES_ROUTER" | sed 's/^-A/-D/g')"
        while read RULE; do
                if [ "$RULE" != "" ]; then
                        CMD=( ip netns exec "$NS" iptables -t nat )
                        while IFS= read -r -d ''; do
                                CMD+=("$REPLY")
                        done < <(xargs printf '%s\0' <<< "$RULE")
                        "${CMD[@]}" 2> /dev/null
                fi
        done <<< "$RULES"
}

# Crea las reglas para el router
function setup_rules {
        local ROUTER="$1"

        wipe_rules "$ROUTER"

        p_info "creating rules for router $ROUTER"

        local NS="qrouter-$ROUTER"
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

        # Create the new rules
        ip netns exec $NS iptables -t nat -I neutron-l3-agent-snat -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "[ANETCON] [FLOAT] " 2> /dev/null
        if [ $? -ne 0 ]; then
                return 1
        fi

        for S in "${SOURCE[@]}"; do
                ip netns exec $NS iptables -t nat -I neutron-l3-agent-snat $S -p tcp -m tcp -m state --state NEW  -m conntrack ! --ctstate DNAT  -j LOG --log-prefix "[ANETCON] [NAT] "
                if [ $? -ne 0 ]; then
                        return 1
                fi
        done
        return 0
}

function check_rules {
        local ROUTER="$1"
        local NS="qrouter-$ROUTER"
        local SOURCE=( )
        local S
        local NET

        p_debug "checking rules for router $ROUTER"

        local NETCOUNT="${#EXPECTED_NETS[@]}"
        if ((NETCOUNT == 0)); then
                NETCOUNT=1
        fi

        local RULE_COUNT="$(echo "$IPTABLES_ROUTER" | wc -l)"
        local EXPECTED_RULES=$((1 + NETCOUNT))
        if ((RULE_COUNT!=EXPECTED_RULES)); then

                p_debug "number of rules for router $ROUTER is not the expected"
                return 1
        fi
        return 0
}

function monitor_routers {
        local ROUTER
        for ROUTER in ${ROUTERS[@]}; do
                p_debug "monitoring router $ROUTER"

                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                if ! check_rules "$ROUTER"; then
                        p_error "rules for router $ROUTER have changed... updating"

                        wipe_rules "$ROUTER"
                        setup_rules "$ROUTER"
                fi
        done
}

function cleanup {
        for ROUTER in ${ROUTERS[@]}; do
                p_info "cleaning up rules for router $ROUTER"
                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                wipe_rules "$ROUTER"
        done
}

function setup {
        for ROUTER in ${ROUTERS[@]}; do
                p_info "setting up rules for router $ROUTER"
                if ! load_rules "$ROUTER"; then
                        p_error "failed to load rules for router $ROUTER"
                        continue
                fi
                wipe_rules "$ROUTER"
                setup_rules "$ROUTER"
        done
}

trap cleanup EXIT
setup

while true; do
        monitor_routers
        sleep $PERIOD
done