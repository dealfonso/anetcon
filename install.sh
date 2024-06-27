#!/bin/bash
INSTALL_FOLDER=/
function fixPath() {
	# local RESULT="${1//\/\///}"
	# if [ "$RESULT" != "$1" ]; then
	# 	fixPath $RESULT
	# else
	# 	echo $RESULT
	# fi
	echo $1 | tr -s '/'
}

# Copy the files
cp etc/logrotate.d/anetcon "$(fixPath "$INSTALL_FOLDER/etc/logrotate.d/")"
cp etc/rsyslog.d/30-anetcon.conf "$(fixPath "$INSTALL_FOLDER/etc/rsyslog.d/")"
cp etc/systemd/system/anetcon.service "$(fixPath "$INSTALL_FOLDER/etc/systemd/system/")"
cp etc/anetcon.conf "$(fixPath "$INSTALL_FOLDER/etc/")"
cp usr/sbin/anetcon.sh "$(fixPath "$INSTALL_FOLDER/usr/sbin/")"
mkdir -p "$(fixPath "$INSTALL_FOLDER/var/log/anetcon")"
mkdir -p "$(fixPath "$INSTALL_FOLDER/var/lib/anetcon")"
chown syslog:adm "$(fixPath "$INSTALL_FOLDER/var/log/anetcon")"
chmod +x "$(fixPath "$INSTALL_FOLDER/usr/sbin/anetcon.sh")"

if [ "$INSTALL_FOLDER" == "/" ]; then
	systemctl daemon-reload
	systemctl enable anetcon
	systemctl start anetcon
fi