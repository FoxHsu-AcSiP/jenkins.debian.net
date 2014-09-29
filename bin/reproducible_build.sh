#!/bin/bash

# Copyright 2014 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# FIXME: needed as long as #763328 (RFP: /usr/bin/diffp) is unfixed...
# fetch git repo for the diffp command used later
if [ -d misc.git ] ; then
	cd misc.git
	git pull
	cd ..
else
	git clone git://git.debian.org/git/reproducible/misc.git misc.git
fi

# create dirs for results
mkdir -p results/
mkdir -p /var/lib/jenkins/userContent/diffp/ /var/lib/jenkins/userContent/pbuilder/

# create sqlite db
PACKAGES_DB=/var/lib/jenkins/reproducible.db
if [ ! -f ${PACKAGES_DB} ] ; then
	sqlite3 ${PACKAGES_DB} '
		CREATE TABLE source_packages
		(name TEXT NOT NULL,
		version TEXT NOT NULL,
		status TEXT NOT NULL
		CHECK (status IN ("FTBFS","reproducible","unreproducible","404", "not for us")),
		build_date TEXT NOT NULL,
		diffp_path TEXT,
		PRIMARY KEY (name))'
	sqlite3 ${PACKAGES_DB} '
		CREATE TABLE source_stats
		(suite TEXT NOT NULL,
		amount INTEGER NOT NULL,
		PRIMARY KEY (suite))'
	sqlite3 ${PACKAGES_DB} '
		CREATE TABLE job_sources
		(name TEXT NOT NULL,
		job TEXT NOT NULL)'
fi
# 30 seconds timeout when trying to get a lock
INIT=/var/lib/jenkins/reproducible.init
cat >/var/lib/jenkins/reproducible.init <<-EOF
.timeout 30000
EOF

# this needs sid entries in sources.list:
grep deb-src /etc/apt/sources.list | grep sid
sudo apt-get update

# if $1 is an integer, build $1 random packages
if [[ $1 =~ ^-?[0-9]+$ ]] ; then
	TMPFILE=$(mktemp)
	curl http://ftp.de.debian.org/debian/dists/sid/main/source/Sources.xz > $TMPFILE
	AMOUNT=$1
	if [ $AMOUNT -gt 0 ] ; then
		REAL_AMOUNT=0
		GUESSES=$(echo "${AMOUNT}*3" | bc)
		PACKAGES=""
		CANDIDATES=$(xzcat $TMPFILE | grep "^Package" | grep -v "^Package-List:" |  cut -d " " -f2 | egrep -v "^linux$"| sort -R | head -$GUESSES | xargs echo)
		for PKG in $CANDIDATES ; do
			if [ $REAL_AMOUNT -eq $AMOUNT ] ; then
				continue
			fi
			RESULT=$(sqlite3 ${PACKAGES_DB} "SELECT name FROM source_packages WHERE name = \"${PKG}\"")
			if [ "$RESULT" = "" ] ; then
				PACKAGES="${PACKAGES} $PKG"
				let "REAL_AMOUNT=REAL_AMOUNT+1"
			fi
		done
		AMOUNT=$REAL_AMOUNT
		for PKG in $PACKAGES ; do
			sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO job_sources VALUES ('$PKG','random')"
		done
	else
		# this is kind of a hack: if $1 is 0, then schedule 33 failed packages which were nadomly picked
		AMOUNT=33
		PACKAGES=$(sqlite3 -init $INIT ${PACKAGES_DB} "SELECT source_packages.name FROM source_packages,job_sources  WHERE (( source_packages.status = 'unreproducible' OR source_packages.status = 'FTBFS') AND source_packages.name = job_sources.name AND job_sources.job = 'random') ORDER BY source_packages.build_date LIMIT $AMOUNT" | xargs -r echo)
		AMOUNT=0
		for PKG in $PACKAGES ; do
			let "AMOUNT=AMOUNT+1"
		done
	fi
	# update amount of available packages (for doing statistics later)
	P_IN_SOURCES=$(xzcat $TMPFILE | grep "^Package" | grep -v "^Package-List:" | cut -d " " -f2 | wc -l)
	sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_stats VALUES (\"sid\", \"${P_IN_SOURCES}\")"
	rm $TMPFILE
else
	PACKAGES="$@"
	AMOUNT="${#@}"
fi
set +x
echo
echo "=============================================================="
echo "The following source packages will be build: ${PACKAGES}"
echo "=============================================================="
echo
set -x

NUM_CPU=$(cat /proc/cpuinfo |grep ^processor|wc -l)
COUNT_TOTAL=0
COUNT_GOOD=0
COUNT_BAD=0
COUNT_SKIPPED=0
GOOD=""
BAD=""
SOURCELESS=""
SKIPPED=""
for SRCPACKAGE in ${PACKAGES} ; do
	let "COUNT_TOTAL=COUNT_TOTAL+1"
	rm b1 b2 -rf
	set +e
	DATE=$(date +'%Y-%m-%d %H:%M')
	VERSION=$(apt-cache showsrc ${SRCPACKAGE} | grep ^Version | cut -d " " -f2 | head -1)

	apt-get source --download-only --only-source ${SRCPACKAGE}=${VERSION}
	RESULT=$?
	if [ $RESULT != 0 ] ; then
		SOURCELESS="${SOURCELESS} ${SRCPACKAGE}"
		echo "Warning: ${SRCPACKAGE} is not a source package, or was removed or renamed. Please investigate."
		sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_packages VALUES (\"${SRCPACKAGE}\", \"${VERSION}\", \"404\", \"$DATE\", \"\")"
	else
		ARCH=$(grep "^Architecture: " ${SRCPACKAGE}_*.dsc| cut -d ":" -f2)
		if [[ ! "$ARCH" =~ "amd64" ]] && [[ ! "$ARCH" =~ "all" ]] && [[ ! "$ARCH" =~ "any" ]] ; then
			sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_packages VALUES (\"${SRCPACKAGE}\", \"${VERSION}\", \"not for us\", \"$DATE\", \"\")"
			echo "Package ${SRCPACKAGE} (${VERSION}) shall only be build on \"$ARCH\" and was thus skipped."
			let "COUNT_SKIPPED=COUNT_SKIPPED+1"
			SKIPPED="${SRCPACKAGE} ${SKIPPED}"
			continue
		fi
		STATUS=$(sqlite3 ${PACKAGES_DB} "SELECT status FROM source_packages WHERE name = \"${SRCPACKAGE}\" AND version = \"${VERSION}\"")
		if [ "$STATUS" = "reproducible" ] && [ $(( $RANDOM % 100 )) -gt 20 ] ; then
			echo "Package ${SRCPACKAGE} (${VERSION}) build reproducibly in the past and was thus randomly skipped."
			let "COUNT_SKIPPED=COUNT_SKIPPED+1"
			SKIPPED="${SRCPACKAGE} ${SKIPPED}"
			continue
		fi
		sudo DEB_BUILD_OPTIONS="parallel=$NUM_CPU" pbuilder --build --basetgz /var/cache/pbuilder/base-reproducible.tgz --distribution sid ${SRCPACKAGE}_*.dsc | tee ${SRCPACKAGE}_${VERSION}.pbuilder.log
		if [ -f /var/cache/pbuilder/result/${SRCPACKAGE}_${VERSION}_amd64.changes ] ; then
			mkdir b1 b2
			dcmd cp /var/cache/pbuilder/result/${SRCPACKAGE}_${VERSION}_amd64.changes b1
			sudo dcmd rm /var/cache/pbuilder/result/${SRCPACKAGE}_${VERSION}_amd64.changes
			rm ${SRCPACKAGE}_*.pbuilder.log /var/lib/jenkins/userContent/pbuilder/${SRCPACKAGE}_*.pbuilder.log
			sudo DEB_BUILD_OPTIONS="parallel=$NUM_CPU" pbuilder --build --basetgz /var/cache/pbuilder/base-reproducible.tgz --distribution sid ${SRCPACKAGE}_${VERSION}.dsc
			dcmd cp /var/cache/pbuilder/result/${SRCPACKAGE}_${VERSION}_amd64.changes b2
			sudo dcmd rm /var/cache/pbuilder/result/${SRCPACKAGE}_${VERSION}_amd64.changes
			set -e
			cat b1/${SRCPACKAGE}_${VERSION}_amd64.changes
			LOGFILE=$(ls ${SRCPACKAGE}_${VERSION}.dsc)
			LOGFILE=$(echo ${LOGFILE%.dsc}.diffp.log)
			./misc.git/diffp b1/${SRCPACKAGE}_${VERSION}_amd64.changes b2/${SRCPACKAGE}_${VERSION}_amd64.changes | tee ./results/${LOGFILE}
			if ! $(grep -qv '^\*\*\*\*\*' ./results/${LOGFILE}) ; then
				rm -f /var/lib/jenkins/userContent/diffp/${SRCPACKAGE}_*.diffp.log > /dev/null 2>&1 
				figlet ${SRCPACKAGE}
				echo
				echo "${SRCPACKAGE} built successfully and reproducibly."
				sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_packages VALUES (\"${SRCPACKAGE}\", \"${VERSION}\", \"reproducible\",  \"$DATE\", \"\")"
				let "COUNT_GOOD=COUNT_GOOD+1"
				GOOD="${SRCPACKAGE} ${GOOD}"
			else
				rm -f /var/lib/jenkins/userContent/diffp/${SRCPACKAGE}_*.diffp.log > /dev/null 2>&1 
				cp ./results/${LOGFILE} /var/lib/jenkins/userContent/diffp/
				echo "Warning: ${SRCPACKAGE} failed to build reproducibly."
				sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_packages VALUES (\"${SRCPACKAGE}\", \"${VERSION}\", \"unreproducible\", \"$DATE\", \"\")"
				let "COUNT_BAD=COUNT_BAD+1"
				BAD="${SRCPACKAGE} ${BAD}"
			fi
			rm b1 b2 -rf
		else
			echo "Warning: ${SRCPACKAGE} failed to build from source."
			sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO source_packages VALUES (\"${SRCPACKAGE}\", \"${VERSION}\", \"FTBFS\", \"$DATE\", \"\")"
			mv ${SRCPACKAGE}_${VERSION}.pbuilder.log /var/lib/jenkins/userContent/pbuilder/
			dcmd rm ${SRCPACKAGE}_${VERSION}.dsc
		fi
	fi

	set +x
	echo "=============================================================="
	echo "$COUNT_TOTAL of $AMOUNT done."
	echo "=============================================================="
	set -x
done

set +x
echo
echo
echo "$COUNT_TOTAL packages attempted to build in total."
echo "$COUNT_GOOD packages successfully built reproducibly: ${GOOD}"
echo "$COUNT_SKIPPED packages skipped (either because they were successfully built reproducibly in the past or because they are not Architecture: 'any' nor 'all' nor 'amd64'): ${SKIPPED}"
echo "$COUNT_BAD packages failed to built reproducibly: ${BAD}"
echo "The following source packages doesn't exist in sid: $SOURCELESS"
