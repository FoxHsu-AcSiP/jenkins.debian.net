#!/bin/bash

# Copyright 2014 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

. /srv/jenkins/bin/common-functions.sh
common_init "$@"

set +x
# define db
PACKAGES_DB=/var/lib/jenkins/reproducible.db
INIT=/var/lib/jenkins/reproducible.init
if [ ! -f $PACKAGES_DB ] ; then
	echo "$PACKAGES_DB doesn't exist, no stats possible."
	exit 1
fi 

declare -A GOOD
declare -A BAD
declare -A UGLY
declare -A SOURCELESS
declare -A NOTFORUS
declare -A STAR
declare -A LINKTARGET
declare -A SPOKENTARGET
LAST24="AND build_date > datetime('now', '-24 hours') "
LAST48="AND build_date > datetime('now', '-48 hours') "
SUITE=sid
AMOUNT=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT amount FROM source_stats WHERE suite = \"$SUITE\"" | xargs echo)
GOOD["all"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"reproducible\" ORDER BY build_date DESC" | xargs echo)
GOOD["last_24h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"reproducible\" $LAST24 ORDER BY build_date DESC" | xargs echo)
GOOD["last_48h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"reproducible\" $LAST48 ORDER BY build_date DESC" | xargs echo)
GOOD["all_abc"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"reproducible\" ORDER BY name" | xargs echo)
COUNT_GOOD=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"reproducible\"")
BAD["all"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"unreproducible\" ORDER BY build_date DESC" | xargs echo)
BAD["last_24h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"unreproducible\" $LAST24 ORDER BY build_date DESC" | xargs echo)
BAD["last_48h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"unreproducible\" $LAST48 ORDER BY build_date DESC" | xargs echo)
BAD["all_abc"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"unreproducible\" ORDER BY name" | xargs echo)
COUNT_BAD=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"unreproducible\"")
UGLY["all"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"FTBFS\" ORDER BY build_date DESC" | xargs echo)
UGLY["last_24h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"FTBFS\" $LAST24 ORDER BY build_date DESC" | xargs echo)
UGLY["last_48h"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"FTBFS\" $LAST48 ORDER BY build_date DESC" | xargs echo)
UGLY["all_abc"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"FTBFS\" ORDER BY name" | xargs echo)
COUNT_UGLY=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"FTBFS\"")
SOURCELESS["all"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"404\" ORDER BY build_date DESC" | xargs echo)
SOURCELESS["all_abc"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"404\" ORDER BY name" | xargs echo)
COUNT_SOURCELESS=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"404\"" | xargs echo)
NOTFORUS["all"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"not for us\" ORDER BY build_date DESC" | xargs echo)
NOTFORUS["all_abc"]=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"not for us\" ORDER BY name" | xargs echo)
COUNT_NOTFORUS=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"not for us\"" | xargs echo)
BLACKLISTED=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT name FROM source_packages WHERE status = \"blacklisted\" ORDER BY name" | xargs echo)
COUNT_BLACKLISTED=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages WHERE status = \"blacklisted\"" | xargs echo)
COUNT_TOTAL=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT COUNT(name) FROM source_packages")
PERCENT_TOTAL=$(echo "scale=1 ; ($COUNT_TOTAL*100/$AMOUNT)" | bc)
PERCENT_GOOD=$(echo "scale=1 ; ($COUNT_GOOD*100/$COUNT_TOTAL)" | bc)
PERCENT_BAD=$(echo "scale=1 ; ($COUNT_BAD*100/$COUNT_TOTAL)" | bc)
PERCENT_UGLY=$(echo "scale=1 ; ($COUNT_UGLY*100/$COUNT_TOTAL)" | bc)
PERCENT_NOTFORUS=$(echo "scale=1 ; ($COUNT_NOTFORUS*100/$COUNT_TOTAL)" | bc)
PERCENT_SOURCELESS=$(echo "scale=1 ; ($COUNT_SOURCELESS*100/$COUNT_TOTAL)" | bc)
GUESS_GOOD=$(echo "$PERCENT_GOOD*$AMOUNT/100" | bc)
SPOKENTARGET["all"]="all tested packages"
SPOKENTARGET["last_24h"]="packages tested in the last 24h"
SPOKENTARGET["last_48h"]="packages tested in the last 48h"
SPOKENTARGET["all_abc"]="all tested packages (sorted alphabetically)"
SPOKENTARGET["dd-list"]="maintainers of unreproducible packages"
SPOKENTARGET["notes"]="packages with notes"

#
# gather notes
#
WORKSPACE=$PWD
cd /var/lib/jenkins
if [ -d notes.git ] ; then
	cd notes.git
	git pull
else
	git clone git://git.debian.org/git/reproducible/notes.git notes.git
fi
cd $WORKSPACE
PACKAGES_YML=/var/lib/jenkins/notes.git/packages.yml
ISSUES_YML=/var/lib/jenkins/notes.git/issues.yml
NOTES_PATH=/var/lib/jenkins/userContent/notes
mkdir -p $NOTES_PATH
rm -f $NOTES_PATH/*.html

declare -A NOTES_PACKAGE
declare -A NOTES_VERSION
declare -A NOTES_ISSUES
declare -A NOTES_BUGS
declare -A NOTES_COMMENTS
declare -A ISSUES_DESCRIPTION
declare -A ISSUES_URL

show_multi_values() {
	TMPFILE=$(mktemp)
	echo "$@" > $TMPFILE
	while IFS= read -r p ; do
		if [ "$p" = "-" ] || [ "$p" = "" ] ; then
			continue
		elif [ "${p:0:2}" = "- " ] ; then
			p="${p:2}"
		fi
		echo "    $PROPERTY = $p"
	done < $TMPFILE
	unset IFS
	rm $TMPFILE
}

ISSUES=$(cat ${ISSUES_YML} | /srv/jenkins/bin/shyaml keys)
for ISSUE in ${ISSUES} ; do
	echo " Issue = ${ISSUE}"
	for PROPERTY in url description ; do
		VALUE="$(cat ${ISSUES_YML} | /srv/jenkins/bin/shyaml get-value ${ISSUE}.${PROPERTY} )"
		if [ "$VALUE" != "" ] ; then
			case $PROPERTY in
				url)		ISSUES_URL[${ISSUE}]=$VALUE
						echo "    $PROPERTY = $VALUE"
						;;
				description)	ISSUES_DESCRIPTION[${ISSUE}]=$VALUE
						show_multi_values "$VALUE"
						;;
			esac
		fi
	done
done

tag_property_loop() {
	BEFORE=$1
	shift
	AFTER=$1
	shift
	TMPFILE=$(mktemp)
	echo "$@" > $TMPFILE
	while IFS= read -r p ; do
		if [ "$p" = "-" ] || [ "$p" = "" ] ; then
			continue
		elif [ "${p:0:2}" = "- " ] ; then
			p="${p:2}"
		fi
		echo "$BEFORE" >> ${NOTE}
		if $BUG ; then
			# turn bugs into links
			p="<a href=\"https://bugs.debian.org/$p\">#$p</a>"
		else
			# turn URLs into links
			p="$(echo $p |sed  -e 's|http[s:]*//[^ ]*|<a href=\"\0\">\0</a>|g')"
		fi
		echo "$p" >> ${NOTE}
		echo "$AFTER" >> ${NOTE}
	done < $TMPFILE
	unset IFS
	rm $TMPFILE
}

issues_loop() {
	TTMPFILE=$(mktemp)
	echo "$@" > $TTMPFILE
	FIRST=true
	while IFS= read -r p ; do
		if [ "${p:0:2}" = "- " ] ; then
			p="${p:2}"
		fi
		if ! $FIRST ; then
			echo "<tr><td>&nbsp;</td>" >> ${NOTE}
		fi
		FIRST=false
		if [ "${ISSUES_URL[$p]}" != "" ] ; then
			echo "<td><a href=\"${ISSUES_URL[$p]}\">$p</a></td><td>" >> ${NOTE}
		else
			echo "<td>$p</td><td>" >> ${NOTE}
		fi
		tag_property_loop "" "<br />" "${ISSUES_DESCRIPTION[$p]}"
		echo "</td></tr>" >> ${NOTE}
	done < $TTMPFILE
	unset IFS
	rm $TTMPFILE
}

create_pkg_note() {
	echo "<!DOCTYPE html><html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />" > ${NOTE}
	echo "<link href=\"../static/style.css\" type=\"text/css\" rel=\"stylesheet\" /></head>" >> ${NOTE}
	echo "<body><table>" >> ${NOTE}

	echo "<tr><td>Version annotated:</td><td colspan=\"2\">${NOTES_VERSION[$1]}</td></tr>" >> ${NOTE}
	BUG=false

	if [ "${NOTES_ISSUES[$1]}" != "" ] ; then
		echo "<tr><td>Identified issues:</td>" >> ${NOTE}
		issues_loop "${NOTES_ISSUES[$1]}"
	fi
	BUG=true
	if [ "${NOTES_BUGS[$1]}" != "" ] ; then
		echo "<tr><td colspan=\"3\">Bugs noted:</td></tr>" >> ${NOTE}
		echo "<tr><td>&nbsp;</td><td colspan=\"2\">" >> ${NOTE}
		tag_property_loop "" "<br />" "${NOTES_BUGS[$1]}"
		echo "</td></tr>" >> ${NOTE}
	fi
	BUG=false
	if [ "${NOTES_COMMENTS[$1]}" != "" ] ; then
		echo "<tr><td colspan=\"3\">Comments:</td></tr>" >> ${NOTE}
		echo "<tr><td>&nbsp;</td><td colspan=\"2\">" >> ${NOTE}
		tag_property_loop "" "<br />" "${NOTES_COMMENTS[$1]}"
		echo "</td></tr>"  >> ${NOTE}
	fi
	echo "</tr>" >> ${NOTE}
	echo "<tr><td colspan=\"3\">&nbsp;</td></tr>" >> ${NOTE}
	echo "<tr><td colspan=\"3\" style=\"text-align:right\"><font size=\"-1\">" >> ${NOTE}
	echo "Notes are stored in <a href=\"http://anonscm.debian.org/cgit/reproducible/notes.git\">notes.git</a>." >> ${NOTE}
	echo "</font></td></tr></table></body></html>" >> ${NOTE}
}

PACKAGES_WITH_NOTES=$(cat ${PACKAGES_YML} | /srv/jenkins/bin/shyaml keys)
for PKG in $PACKAGES_WITH_NOTES ; do
	echo " Package = ${PKG}"
	NOTES_PACKAGE[${PKG}]=" <a href=\"$JENKINS_URL/userContent/notes/${PKG}_note.html\" target=\"main\">notes</a> "
	for PROPERTY in version issues bugs comments ; do
		VALUE="$(cat ${PACKAGES_YML} | /srv/jenkins/bin/shyaml get-value ${PKG}.${PROPERTY} )"
		if [ "$VALUE" != "" ] ; then
			case $PROPERTY in
				version)	NOTES_VERSION[${PKG}]=$VALUE
						echo "    $PROPERTY = $VALUE"
						;;
				issues)		NOTES_ISSUES[${PKG}]=$VALUE
						show_multi_values "$VALUE"
						;;
				bugs)		NOTES_BUGS[${PKG}]=$VALUE
						show_multi_values "$VALUE"
						;;
				comments)	NOTES_COMMENTS[${PKG}]=$VALUE
						show_multi_values "$VALUE"
						;;
			esac
		fi
	done
	NOTE=$NOTES_PATH/${PKG}_note.html
	create_pkg_note $PKG
done

#
# end note parsing
#



write_summary() {
	echo "$1" >> $SUMMARY
}

mkdir -p /var/lib/jenkins/userContent/rb-pkg/
write_pkg_frameset() {
	FRAMESET="/var/lib/jenkins/userContent/rb-pkg/$1.html"
	cat > $FRAMESET <<-EOF
<!DOCTYPE html>
<html>
	<head>
	</head>
	<frameset framespacing="0" rows="42,*" frameborder="0" noresize>
		<frame name="top" src="$1_navigation.html" target="top">
		<frame name="main" src="$2" target="main">
	</frameset>
</html>
EOF
}

init_navi_frame() {
	echo "<!DOCTYPE html><html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />" > $NAVI
	echo "<link href=\"../static/style.css\" type=\"text/css\" rel=\"stylesheet\" /></head>" >> $NAVI
	echo "<body><table><tr><td><font size=+1>$1</font> $2" >> $NAVI
	# icons taken from tango-icon-theme (0.8.90-5)
	# licenced under http://creativecommons.org/licenses/publicdomain/
	case "$3" in
		"reproducible")		ICON=weather-clear.png
					;;
		"unreproducible")	if [ "$5" != "" ] ; then
						ICON=weather-showers-scattered.png
					else
						ICON=weather-showers.png
					fi
					;;
		"FTBFS")		ICON=weather-storm.png
					;;
		"404")			ICON=weather-severe-alert.png
					;;
		"not for us")		ICON=weather-few-clouds-night.png
					;;
		"blacklisted")		ICON=error.png
					;;
	esac
	echo "<img src=\"../static/$ICON\" /> $3" >> $NAVI
	echo "<font size=-1>at $4:</font> " >> $NAVI
}

append2navi_frame() {
	echo "$1" >> $NAVI
}

finish_navi_frame() {
	echo "</td><td style=\"text-align:right\"><font size=\"-1\"><a href=\"$JENKINS_URL/userContent/index_notes.html\" target=\"_parent\">notes</a>/<a href=\"http://bugs.debian.org/cgi-bin/pkgreport.cgi?usertag=reproducible-builds@lists.alioth.debian.org\" target=\"_parent\">bugs</a>/<a href=\"$JENKINS_URL/userContent/reproducible.html\" target=\"_parent\">stats</a> for <a href=\"https://wiki.debian.org/ReproducibleBuilds\" target=\"_parent\">reproducible builds</a></font></td></tr></table></body></html>" >> $NAVI
}

process_packages() {
	for PKG in $@ ; do
		RESULT=$(sqlite3 -init $INIT $PACKAGES_DB "SELECT build_date,version,status FROM source_packages WHERE name = \"$PKG\"")
		BUILD_DATE=$(echo $RESULT|cut -d "|" -f1)
		VERSION=$(echo $RESULT|cut -d "|" -f2)
		STATUS=$(echo $RESULT|cut -d "|" -f3)
		# remove epoch
		EVERSION=$(echo $VERSION | cut -d ":" -f2)
		if $BUILDINFO_SIGNS && [ -f "/var/lib/jenkins/userContent/buildinfo/${PKG}_${EVERSION}_amd64.buildinfo" ] ; then
			STAR[$PKG]="<font color=\"#333333\" size=\"-1\">&beta;</font>" # used to be a star...
		fi
		# only build $PKG pages if they don't exist or are older than $BUILD_DATE
		NAVI="/var/lib/jenkins/userContent/rb-pkg/${PKG}_navigation.html"
		FILE=$(find $(dirname $NAVI) -name $(basename $NAVI) ! -newermt "$BUILD_DATE" 2>/dev/null || true)
		# if no navigation exists, or is older than last build_date or if a note exist...
		if [ ! -f $NAVI ] || [ "$FILE" != "" ] || [ "${NOTES_PACKAGE[${PKG}]}" != "" ] ; then
			MAINLINK=""
			init_navi_frame "$PKG" "$VERSION" "$STATUS" "$BUILD_DATE" "${STAR[$PKG]}"
			append2navi_frame "${NOTES_PACKAGE[${PKG}]}"
			if [ -f "/var/lib/jenkins/userContent/buildinfo/${PKG}_${EVERSION}_amd64.buildinfo" ] ; then
				append2navi_frame " <a href=\"$JENKINS_URL/userContent/buildinfo/${PKG}_${EVERSION}_amd64.buildinfo\" target=\"main\">buildinfo</a> "
				MAINLINK="$JENKINS_URL/userContent/buildinfo/${PKG}_${EVERSION}_amd64.buildinfo"
			fi
			if [ -f "/var/lib/jenkins/userContent/dbd/${PKG}_${EVERSION}.debbindiff.html" ] ; then
				append2navi_frame " <a href=\"$JENKINS_URL/userContent/dbd/${PKG}_${EVERSION}.debbindiff.html\" target=\"main\">debbindiff</a> "
				MAINLINK="$JENKINS_URL/userContent/dbd/${PKG}_${EVERSION}.debbindiff.html"
			fi
			RBUILD_LOG="rbuild/${PKG}_${EVERSION}.rbuild.log"
			if [ -f "/var/lib/jenkins/userContent/${RBUILD_LOG}" ] ; then
				SIZE=$(du -sh "/var/lib/jenkins/userContent/${RBUILD_LOG}" |cut -f1)
				append2navi_frame " <a href=\"$JENKINS_URL/userContent/${RBUILD_LOG}\" target=\"main\">rbuild ($SIZE)</a> "
				if [ "$MAINLINK" = "" ] ; then
					MAINLINK="$JENKINS_URL/userContent/${RBUILD_LOG}"
				fi
			fi
			append2navi_frame " <a href=\"https://packages.qa.debian.org/${PKG}\" target=\"main\">PTS</a> "
			append2navi_frame " <a href=\"https://bugs.debian.org/src:${PKG}\" target=\"main\">BTS</a> "
			append2navi_frame " <a href=\"https://sources.debian.net/src/${PKG}/\" target=\"main\">sources</a> "
			append2navi_frame " <a href=\"https://sources.debian.net/src/${PKG}/${VERSION}/debian/rules\" target=\"main\">debian/rules</a> "

			if [ "${NOTES_PACKAGE[${PKG}]}" != "" ] ; then
				MAINLINK="$JENKINS_URL/userContent/notes/${PKG}_note.html"
			fi
			finish_navi_frame
			write_pkg_frameset "$PKG" "$MAINLINK"
		fi
		if [ -f "/var/lib/jenkins/userContent/rbuild/${PKG}_${EVERSION}.rbuild.log" ] ; then
			if [ "${NOTES_PACKAGE[${PKG}]}" != "" ] ; then
				NOTED="N"
			else
				NOTED=""
			fi
			LINKTARGET[$PKG]="<a href=\"$JENKINS_URL/userContent/rb-pkg/$PKG.html\">$PKG</a>${STAR[$PKG]}$NOTED"
		else
			LINKTARGET[$PKG]="$PKG"
		fi
	done
}

force_package_targets() {
	for PKG in $@ ; do
		LINKTARGET[$PKG]="<a href=\"$JENKINS_URL/userContent/rb-pkg/$PKG.html\">$PKG</a>${STAR[$PKG]}"
	done
}

link_packages() {
	for PKG in $@ ; do
		write_summary " ${LINKTARGET[$PKG]} "
	done
}

write_summary_header() {
	rm -f $SUMMARY
	write_summary "<!DOCTYPE html><html><head>"
	write_summary "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />"
	write_summary "<link href=\"static/style.css\" type=\"text/css\" rel=\"stylesheet\" /></head>"
	write_summary "<body><header><h2>$2</h2>"
	if [ "$1" = "$MAINVIEW" ] ; then
		write_summary "<p>These pages are updated every three hours. Results are obtained from <a href=\"$JENKINS_URL/view/reproducible\">several build jobs running on jenkins.debian.net</a>. Thanks to <a href=\"https://www.profitbricks.com\">Profitbricks</a> for donating the virtual machine it's running on!</p>"
	fi
	write_summary "<p>$COUNT_TOTAL packages attempted to build so far, that's $PERCENT_TOTAL% of $AMOUNT source packages in Debian $SUITE currently. Out of these, $PERCENT_GOOD% were successful, so quite wildly guessing this roughy means about $GUESS_GOOD <a href=\"https://wiki.debian.org/ReproducibleBuilds\">packages should be reproducibly buildable!</a>"
	if [ "${1:0:3}" = "all" ] || [ "$1" = "dd-list" ] ; then
		write_summary " Join <code>#debian-reproducible</code> on OFTC to get support for making sure your packages build reproducibly too!"
	fi
	write_summary "</p>"
	write_summary "<p><ul>Other views for these build results:"
	for TARGET in notes $ALLVIEWS dd-list ; do
		if [ "$TARGET" = "$1" ] ; then
			continue
		fi
		write_summary "<li><a href=\"index_${TARGET}.html\">${SPOKENTARGET[$TARGET]}</a></li>"
	done
	write_summary "</ul></p>"
	write_summary "</header>"
}

write_summary_footer() {
	write_summary "<hr/><p><font size='-1'><a href=\"$JENKINS_URL/userContent/reproducible.html\">Static URL for this page.</a> Last modified: $(date). Copyright 2014 <a href=\"mailto:holger@layer-acht.org\">Holger Levsen</a>, GPL-2 licensed. <a href=\"https://jenkins.debian.net/userContent/about.html\">About jenkins.debian.net</a></font>"
	write_summary "</p></body></html>"
}

publish_summary() {
	cp $SUMMARY /var/lib/jenkins/userContent/
	if [ "$VIEW" = "$MAINVIEW" ] ; then
		cp $SUMMARY /var/lib/jenkins/userContent/reproducible.html
	fi
	rm $SUMMARY
}

echo "Processing $COUNT_TOTAL packages... this will take a while."
BUILDINFO_SIGNS=true
process_packages ${BAD["all"]}
BUILDINFO_SIGNS=false
process_packages ${UGLY["all"]} ${GOOD["all"]} ${SOURCELESS["all"]} ${NOTFORUS["all"]} $BLACKLISTED

MAINVIEW="all_abc"
ALLVIEWS="last_24h last_48h all all_abc"
for VIEW in $ALLVIEWS ; do
	SUMMARY=index_${VIEW}.html
	echo "Starting to write $SUMMARY page."
	write_summary_header $VIEW "Statistics for reproducible builds of ${SPOKENTARGET[$VIEW]}"
	if [ "${VIEW:0:3}" = "all" ] ; then
		FINISH=":"
	else
		SHORTER_SPOKENTARGET=$(echo ${SPOKENTARGET[$VIEW]} | cut -d "(" -f1)
		FINISH=", from $SHORTER_SPOKENTARGET these were:"
	fi
	write_summary "<p>$COUNT_BAD packages ($PERCENT_BAD% of $COUNT_TOTAL) failed to built reproducibly in total$FINISH <code>"
	link_packages ${BAD[$VIEW]}
	write_summary "</code></p>"
	write_summary
	write_summary "<p>$COUNT_UGLY packages ($PERCENT_UGLY%) failed to build from source in total$FINISH <code>"
	link_packages ${UGLY[$VIEW]}
	write_summary "</code></p>"
	if [ "${VIEW:0:3}" = "all" ] && [ $COUNT_SOURCELESS -gt 0 ] ; then
		write_summary "<p>For $COUNT_SOURCELESS ($PERCENT_SOURCELESS%) packages in total sources could not be downloaded: <code>${SOURCELESS[$VIEW]}</code></p>"
	fi
	if [ "${VIEW:0:3}" = "all" ] && [ $COUNT_NOTFORUS -gt 0 ] ; then
		write_summary "<p>In total there were $COUNT_NOTFORUS ($PERCENT_NOTFORUS%) packages which are neither Architecture: 'any' nor 'all' nor 'amd64' nor 'linux-amd64': <code>${NOTFORUS[$VIEW]}</code></p>"
	fi
	if [ "${VIEW:0:3}" = "all" ] && [ $COUNT_BLACKLISTED -gt 0 ] ; then
		write_summary "<p>$COUNT_BLACKLISTED packages are blacklisted and will never be tested here: <code>$BLACKLISTED</code></p>"
	fi
	write_summary "<p>$COUNT_GOOD packages ($PERCENT_GOOD%) successfully built reproducibly$FINISH <code>"
	link_packages ${GOOD[$VIEW]}
	write_summary "</code></p>"
	write_summary "<p><font size=\"-1\">A &beta; sign after a package which is unreproducible indicates that a .buildinfo file was generated."
	write_summary "This means the <a href=\"https://wiki.debian.org/ReproducibleBuilds#The_basics_for_making_packages_build_reproducible\">basics for building packages reproducibly are covered</a> :-)</font></p>"
	write_summary_footer
	publish_summary
done

VIEW=dd-list
SUMMARY=index_${VIEW}.html
echo "Starting to write $SUMMARY page."
write_summary_header $VIEW "Statistics for reproducible builds of ${SPOKENTARGET[$VIEW]}"
TMPFILE=$(mktemp)
echo "${BAD["all"]}" | dd-list -i > $TMPFILE
write_summary "<p><pre>"
while IFS= read -r LINE ; do
	if [ "${LINE:0:3}" = "   " ] ; then
		PACKAGE=$(echo "${LINE:3}" | cut -d " " -f1)
		UPLOADERS=$(echo "${LINE:3}" | cut -d " " -f2-)
		if [ "$UPLOADERS" = "$PACKAGE" ] ; then
			UPLOADERS=""
		fi
		write_summary "   <a href=\"$JENKINS_URL/userContent/rb-pkg/$PACKAGE.html\">$PACKAGE</a> $UPLOADERS"
	else
		LINE="$(echo $LINE | sed 's#&#\&amp;#g ; s#<#\&lt;#g ; s#>#\&gt;#g')"
		write_summary "$LINE"
	fi
done < $TMPFILE
write_summary "</pre></p>"
rm $TMPFILE
write_summary_footer
publish_summary

VIEW=notes
SUMMARY=index_${VIEW}.html
echo "Starting to write $SUMMARY page."
write_summary_header $VIEW "Statistics for reproducible builds of ${SPOKENTARGET[$VIEW]}"
write_summary "<p>Packages which have notes: <code>"
for PKG in $PACKAGES_WITH_NOTES ; do
	NOTES_PACKAGE[${PKG}]=""
done
force_package_targets $PACKAGES_WITH_NOTES
PACKAGES_WITH_NOTES=$(echo $PACKAGES_WITH_NOTES | sed -s "s# #\n#g" | sort | xargs echo)
link_packages $PACKAGES_WITH_NOTES
write_summary "</code></p>"
write_summary "<p><font size=\"-1\">Notes are stored in <a href=\"http://anonscm.debian.org/cgit/reproducible/notes.git\">notes.git</a>.</font></font>"
write_summary_footer
publish_summary

echo "Enjoy https://jenkins.debian.net/userContent/reproducible.html"
