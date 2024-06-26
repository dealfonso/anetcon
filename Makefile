APP_NAME?=anetcon
INSTALL_FOLDER?=/
ETC_FOLDER=$(INSTALL_FOLDER)/etc
VAR_FOLDER=$(INSTALL_FOLDER)/var/log/$(APP_NAME)

.PHONY: install

install:
	@mkdir -p $(INSTALL_FOLDER)
	@mkdir -p $(VAR_FOLDER)
	@cp -r -n etc $(INSTALL_FOLDER) || true	# This is because cp -n returns 1 if any file exists
	@cp -r -n usr $(INSTALL_FOLDER) || true	# This is because cp -n returns 1 if any file exists
	@chown -R syslog:adm $(VAR_FOLDER)
	@chmod +x $(INSTALL_FOLDER)/usr/bin/$(APP_NAME).sh
