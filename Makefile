# dcape Makefile
SHELL             = /bin/bash
CFG               = .env
CFG_BAK          ?= $(CFG).bak
DCAPE_USED        = 1

TZ               ?= $(shell cat /etc/timezone)

PROJECT_NAME     ?= dcape

# Postgresql Database image
PG_IMAGE         ?= postgres:12.1-alpine
# Postgresql Database superuser password
PG_DB_PASS       ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 2>/dev/null | head -c14; echo)
# Postgresql Database encoding
PG_ENCODING      ?= en_US.UTF-8
# port on localhost postgresql listen on
PG_PORT_LOCAL    ?= 5433
# Dump name suffix to load on db-create
PG_SOURCE_SUFFIX ?=
# shared memory
PG_SHM_SIZE      ?= 64mb

# ------------------------------------------------------------------------------

define CONFIG_DEF
# dcape config file, generated by make $(CFG)

# General settings

# containers name prefix
PROJECT_NAME=$(PROJECT_NAME)

# Default domain
DOMAIN=$(DOMAIN)

# create db cluster with this timezone
# (also used by gitea container)
TZ=$(TZ)

# Postgresql Database image
PG_IMAGE=$(PG_IMAGE)
# Postgresql Database superuser password
PG_DB_PASS=$(PG_DB_PASS)
# Postgresql Database encoding
PG_ENCODING=$(PG_ENCODING)
# port on localhost postgresql listen on
PG_PORT_LOCAL=$(PG_PORT_LOCAL)
# shared memory
PG_SHM_SIZE=$(PG_SHM_SIZE)

endef
export CONFIG_DEF

# ------------------------------------------------------------------------------

# if exists - load old values
-include $(CFG_BAK)
export

-include $(CFG)
export

.PHONY: help

# ------------------------------------------------------------------------------

all: help

# Upgrade postgres major version with pg_upgrade
pg_upgrade:
	@echo "*** $@ *** " ; \
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	PG_OLD=`cat ./var/data/db/PG_VERSION` ; \
	PG_NEW=`docker inspect --type=image $$PG_IMAGE | jq -r '.[0].ContainerConfig.Env[] | capture("PG_MAJOR=(?<a>.+)") | .a'`  ; \
	echo "*** $@ *** from $$PG_OLD to $$PG_NEW" ; \
	echo -n "Checking PG is down..." ; \
	if [[ `docker inspect -f "{{.State.Running}}" $$DCAPE_DB 2>/dev/null` == true ]] ; then \
		echo "Postgres container not stop. Exit" && exit 1 ; \
	else \
		echo "Postgres container not run. Continue" ; \
	fi ; \
	echo "Move current postgres data directory to ./var/data/db_$$PG_OLD" ; \
	mkdir ./var/data/db_$$PG_OLD ; \
	mv ./var/data/db/* ./var/data/db_$$PG_OLD/ ; \
	cp ./var/data/db_$$PG_OLD/postgresql.conf ./var/data/db_$$PG_OLD/postgresql_store.conf ; \
	sed -i "s%include_dir = '/opt/conf.d'%#include_dir = '/opt/conf.d'%" ./var/data/db_$$PG_OLD/postgresql.conf ; \
	docker pull tianon/postgres-upgrade:$$PG_OLD-to-$$PG_NEW ; \
	docker run --rm \
    	-v $$PWD/var/data/db_$$PG_OLD:/var/lib/postgresql/$$PG_OLD/data \
    	-v $$PWD/var/data/db:/var/lib/postgresql/$$PG_NEW/data \
    	tianon/postgres-upgrade:$$PG_OLD-to-$$PG_NEW ; \
	cp -f ./var/data/db_$$PG_OLD/pg_hba.conf ./var/data/db/pg_hba.conf ; \
	cp -f ./var/data/db_$$PG_OLD/postgresql_store.conf ./var/data/db/postgresql.conf ; \
	echo "If the process succeeds, edit pg_hba.conf, other conf and start postgres container or dcape. \
   		For more info see https://github.com/dopos/dcape/blob/master/POSTGRES.md"

# Upgrade postgres major version with pg_dumpall-psql
# Create dump for claster Postgres
pg_dumpall:
	@echo "Start $@ to pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz" ;\
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	docker exec -u postgres $$DCAPE_DB pg_dumpall | gzip -7 -c > \
		./var/data/db-backup/pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz

# Load dump for claster Postgres
pg_load_dumpall:
	@echo "Start $@ ..." ; \
	echo "Load dump file: pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz" ;\
	docker exec -u postgres -e PROJECT_NAME=$${PROJECT_NAME} $${PROJECT_NAME}_db_1 \
		bash -c 'zcat /opt/backup/pg_dumpall_$${PROJECT_NAME}_`date +"$d.%m.%Y"`.sql.gz | psql' ; \
	echo "Load dump complete. Start databases ANALYZE." ; \
	docker exec -u postgres $${PROJECT_NAME}_db_1 psql -c "ANALYZE" && \
		echo "ANALYZE complete."


# ------------------------------------------------------------------------------
# Upgrade postgres databases via pipeline
upgrade-pg-via-pipe:
	@echo "*** $@ *** " ; \
    DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
    docker pull $$PG_IMAGE ; \
    PG_NEW=`docker inspect --type=image $$PG_IMAGE | jq -r '.[0].ContainerConfig.Env[] | capture("PG_MAJOR=(?<a>.+)") | .a'`  ; \
    echo "Preparing the container with the new postgres version" ; \
    PG_PORT_NEW=$(shell expr $(PG_PORT_LOCAL) + 1) ; \
    DCAPE_DB_NEW="dcape_db_new" ; \
		echo "Deny connections from hosts" ; \
		sed -i 's/host all all all md5/#host all all all md5/' $$PWD/var/data/db/pg_hba.conf ; \
    docker run --rm -d \
			--name dcape_db_new \
			-v $$PWD/var/data/db_$$PG_NEW:/var/lib/postgresql/data \
			-e "TZ=$$TZ" \
			-e "LANG=$$PG_ENCODING" \
			--network="d4s_default" \
			-p "$$PG_PORT_NEW:5432" \
			$$PG_IMAGE ; \
    echo -n "Checking for new version PG is ready..." ; \
      until [[ `docker inspect -f "{{.State.Running}}" $$DCAPE_DB_NEW` == true ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok. Run the migration on all databases" ; \
	  PG_NEW=`docker inspect --type=image $$PG_IMAGE | jq -r '.[0].ContainerConfig.Env[] | capture("PG_MAJOR=(?<a>.+)") | .a'`  ; \
    DCAPE_DB_NEW="dcape_db_new" ; \
	  docker exec -i -u postgres $$DCAPE_DB_NEW /bin/bash -c "echo "db:5432:*:postgres:$$PG_DB_PASS" > ~/.pgpass && chmod 0600 ~/.pgpass" ; \
	  docker exec -i -u postgres $$DCAPE_DB_NEW /bin/bash -c	"pg_dumpall -h db -p 5432 | psql && echo "Migration complete." " ; \
	  docker stop $$DCAPE_DB_NEW ; \
	  docker stop $$DCAPE_DB ; \
	  mv ./var/data/db ./var/data/db_previous_version ; \
	  cp ./var/data/db_/postgresql.conf ./var/data/db_$$PG_OLD/postgresql_store.conf ; \

	# echo "If the process succeeds, edit pg_hba.conf, other conf and start postgres container or dcape. \
  #  		For more info see https://github.com/dopos/dcape/blob/master/POSTGRES.md"

psql:
	@DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -it $$DCAPE_DB psql -U postgres

## Run local psql
psql-local:
	@psql -h localhost

# ------------------------------------------------------------------------------

help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
