# ANetCon: Auditing Network Connections 

ANetCon is a set of scripts that audit the network connections of a system in an OpenStack deployment. The idea is to log any outgoing connection in the system to be used in case of a security incident.

## Installing

To install ANetCon, you need to clone the repository manually copy the files to the corresponding locations (as root):

```bash
cp etc/logrotate.d/anetcon /etc/logrotate.d/
cp etc/rsyslog.d/30-anetcon.conf /etc/rsyslog.d/
cp etc/systemd/system/anetcon.service /etc/systemd/system/
cp etc/anetcon.conf /etc/
cp usr/sbin/anetcon.sh /usr/sbin/
mkdir -p /var/log/anetcon
mkdir -p /var/lib/anetcon
chown syslog:adm /var/log/anetcon
chmod +x /usr/sbin/anetcon.sh
```

Then you need to enable the service:

```bash
$ systemctl enable anetcon
```

## What ANETCON does

The original purpose of ANetCon is to audit the network connections of a system in an OpenStack deployment. It logs any outgoing connection in the system to be used in case of a security incident.

It works by logging any new _tcp_ connection in the system (either inside a namespace or not), and stores it in a log file, depending on the type of connection (DNAT or not DNAT).

If we use in the `network node` of OpenStack, the result is that we'll have a log file with the connections of any outgoing NAT connection start from the instances, and a log file with the incoming connections to any floating IP connection.

> The idea is to keep a log of any connection start, to be used in case of a security incident.

### Logging the new connections using `iptables`

ANetCon adds a rule to the `iptables` to log any outgoing or incoming connection that uses `DNAT` (along with the creation of a custom chain called `anetcon` that will be executed after **POSTROUTING**).

```iptables
-A anetcon -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "[ANETCON] [FLOAT] "
-A anetcon -p tcp -m tcp -m state --state NEW -m conntrack ! --ctstate DNAT -j LOG --log-prefix "[ANETCON] [NAT] "
```

### Logging the connections inside namespaces

`anetcon` works for any network _out of the box_, to log NAT connections. But its original purpose was to work with OpenStack, inside the namespaces created by the `neutron` service. So it is possible to define the set of _namespaces_ to be audited in the configuration file. So, if we have a namespace called `qrouter-12345678-90ab-cdef-1234-567890abcdef` that we want to monitor, we can add it to the configuration file `/etc/anetcon.conf` like this:

```ini
...
NAMESPACES=("qrouter-12345678-90ab-cdef-1234-567890abcdef")
...
```

Then, when the `anetcon` service starts, it will add the rules to the `iptables` in that namespace.:

```bash
$ ip netns exec qrouter-12345678-90ab-cdef-1234-567890abcdef iptables -t nat -S
...
-N anetcon
...
-A POSTROUTING -j anetcon
-A anetcon -p tcp -m tcp -m state --state NEW -m conntrack --ctstate DNAT -j LOG --log-prefix "[ANETCON] [FLOAT] "
-A anetcon -p tcp -m tcp -m state --state NEW -m conntrack ! --ctstate DNAT -j LOG --log-prefix "[ANETCON] [NAT] "
...
```

### Sorting the logs in files, depending on the type of connection

Then, using the `rsyslog` service, the logs are sent to the file `/var/log/anetcon/anetcon.nat.log` and `/var/log/anetcon/anetcon.float.log`, depending on the type of connection (DNAT or not DNAT). The configuration to make it possible is included in the file `/etc/rsyslog.d/30-anetcon.conf`.

> Modern Linux distros does not allow to log the `iptables` logs from inside a namespace, and so it needs to activate it by issuing the command `echo "1" > /proc/sys/net/netfilter/nf_log_all_netns`.

### Rotating the logs

ANetCon also includes the configuration to rotate the logs using `logrotate` in file `/etc/logrotate.d/anetcon`.

## Configuration

The configuration file `/etc/anetcon.conf` is used to define the set of namespaces to be audited. It is a simple `bash` script that defines the variable `NAMESPACES` as an array of strings where each of the items is a regular expression to be used with `grep` to filter the namespaces to be audited. It also considers the special value `default` that means the root namespace (i.e. no namespace).

> To integrate with any router from OpenStack, you can set `NAMESPACES` to `("^qrouter-.*$")`.

The file also includes the variable `NETS` that is an array of pairs of strings where the first one corresponds to the name of one router and the second one is a space separated list of networks to be audited. If the name of a router appears in the list, only the networks listed will be audited. If the name of a router does not appear, any network will be audited.

```bash
# Setting this other than "empty value", anetcon will show more information
# DEBUG=true

# Space separated list of namespaces that should be monitored by anetcon.
#       (*) each entry is a regular expression to be used with grep
#       (*) the special value "default" means the root namespace (i.e. no namespace)
# NAMESPACES=(qrouter-68fa7669-72b1-457b-8246-22ffef772f79)
#       (*) In the example, anetcon will monitor the namespaces for any router from OpenStack
NAMESPACES=( "^qrouter-.*$" )

# Specific networks that should be monitored for each namespace. The syntax is a bash array where there appear the router and a space separated list of networks to monitor
#       (*) In the example, the router "qrouter-a4fadad3-e529-4329-a086-010b84363596" will be monitored for networks "10.0.0.0/8" and "192.168.1.1/24".
#
# In case that a router does not appear, any network will be monitored
#NETS=( "qrouter-a4fadad3-e529-4329-a086-010b84363596" "10.0.0.0/8 192.168.1.1/24" )

# Period of checks for changes in the namespace. Anetcon will watch for the rules and will restore them in case that they are wiped
PERIOD=30

##########################################################################################################################
#
# WARNING ZONE:
#
#   from here on, the configuration is for advanced users. Please, do not touch if you do not know what you are doing
#
##########################################################################################################################

# The name of the iptables chain for anetcon (i.e. it will be issued a "iptables -t nat -N <CHAIN_NAME>" command)
#   (*) please do not touch if you do not know what you are doing
# CHAIN_NAME=anetcon

# The prefix for the log messages in the iptables file. It MUST coincide with the content in file 'rsyslog.d/30-anetcon.conf' in order
#   to be able to filter the messages in the log file and put it in the right file
#   (*) please do not touch if you do not know what you are doing
#   (*) WARNING: have in mind that the final log prefix will be "<LOG_PREFIX><LOG_PREFIX_DNAT|LOG_PREFIX_OTHER><LOG_NAMESPACE_HASH> ",
#                and the maximum size of a log message is 29 chars. If the resulting message is longer, it will be truncated and so
#                the log message will not be properly identified which may result in ANETCON not working properly
# LOG_PREFIX="[ANETCON]"
# LOG_PREFIX_DNAT="[D]"
# LOG_PREFIX_OTHER="[X]"

# Whether to include a 10 chars hash of the namespace in the log messages so each namespace can be identified (they are 10 chars
#   because the hash will be [<8-digit hash>]).
#  (*) true: include the hash; <any other value>: do not include the hash
# LOG_NAMESPACE_HASH=true

# File to store the hash of the namespaces to ease the identification of the logs
#   - if empty value, the hash will not be stored
#   - the path is assumed to exist and be writable by the user that runs anetcon
#   (*) please do not touch if you do not know what you are doing
# NAMESPACE_HASH_FILE=/var/lib/anetcon/namespace.hash
```

> It is also possible to enable the debug mode by setting the variable `DEBUG` to `true`, to get a lot more information during the execution of the script. And it is also possible to set the period of checks for changes in the namespace by setting the variable `PERIOD` to the number of seconds between checks.

The rest of options are for advanced users and should not be touched if you do not know what you are doing. For example:

- `CHAIN_NAME`: is the name of the iptables chain to use by ANetCon. The default value is `anetcon`, but you can change it if you need.
- `LOG_PREFIX`: is the prefix for the log messages in the iptables file. It MUST coincide with the content in file `rsyslog.d/30-anetcon.conf` in order to be able to filter the messages in the log file and put it in the right file. Moreover, the maximum size of a log message is 29 chars. If the resulting message prefix is longer, it will be truncated and so the log message will not be properly identified which may result in ANETCON not working properly.

## License

ANetCon is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full license text.
