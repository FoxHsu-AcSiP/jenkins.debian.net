#!/usr/bin/python3
# -*- coding: utf-8 -*-

# clean-notes: sort and clean the notes stored in notes.git
# Copyright © 2015 Mattia Rizzolo <mattia@mapreri.org>
# Licensed under GPL-2+
#
# Depends: python3

import os
import re
import sys
import sqlite3
import logging
import argparse
import datetime
from string import Template

DEBUG = False
QUIET = False

BIN_PATH = '/srv/jenkins/bin'
BASE = '/var/lib/jenkins'

REPRODUCIBLE_DB = BASE + '/userContent/reproducible.db'
REPRODUCIBLE_JSON = BASE + '/userContent/reproducible.json'

NOTES_URI = '/userContent/notes'
ISSUES_URI = '/userContent/issues'
RB_PKG_URI = '/usrtContent/rb-pkg'
NOTES_PATH = BASE + NOTES_URI
ISSUES_PATH = BASE + ISSUES_URI
RB_PKG_PATH = BASE + RB_PKG_URI

REPRODUCIBLE_URL = 'https://reproducible.debian.net'
JENKINS_URL = 'https://jenkins.debian.net'

parser = argparse.ArgumentParser()
group = parser.add_mutually_exclusive_group()
group.add_argument("-d", "--debug", action="store_true")
group.add_argument("-q", "--quiet", action="store_true")
args = parser.parse_args()
log_level = logging.INFO
if args.debug or DEBUG:
    log_level = logging.DEBUG
if args.quiet or QUIET:
    log_level = logging.ERROR
logging.basicConfig(level=log_level)

logging.debug("BIN_PATH:\t" + BIN_PATH)
logging.debug("BASE:\t" + BASE)
logging.debug("NOTES_URI:\t" + NOTES_URI)
logging.debug("ISSUES_URI:\t" + ISSUES_URI)
logging.debug("NOTES_PATH:\t" + NOTES_PATH)
logging.debug("ISSUES_PATH:\t" + ISSUES_PATH)
logging.debug("RB_PKG_URI:\t" + RB_PKG_URI)
logging.debug("RB_PKG_PATH:\t" + RB_PKG_PATH)
logging.debug("REPRODUCIBLE_DB:\t" + REPRODUCIBLE_DB)
logging.debug("REPRODUCIBLE_JSON:\t" + REPRODUCIBLE_JSON)
logging.debug("JENKINS_URL:\t\t" + JENKINS_URL)
logging.debug("REPRODUCIBLE_URL:\t" + REPRODUCIBLE_URL)

html_header = Template("""<!DOCTYPE html>
<html>\n<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<link href="/userContent/static/style.css" type="text/css" rel="stylesheet" />
<title>$page_title</title>\n</head>
<body>
""")
html_footer = Template("""<hr /><p style="font-size:0.9em;">There is more
information <a href="%s/userContent/about.html">about jenkins.debian.net</a>
and about <a href="https://wiki.debian.org/ReproducibleBuilds"> reproducible
builds of Debian</a> available elsewhere. Last update: $date.
Copyright 2014-%s <a href="mailto:holger@layer-acht.org">Holger Levsen</a>,
GPL-2 licensed. The weather icons are public domain and have been taken from
the <a href=http://tango.freedesktop.org/Tango_Icon_Library target=_blank>Tango
Icon Library</a>.</p>
</body></html>""" % (JENKINS_URL, datetime.datetime.now().strftime('%Y')))

html_head_page = Template("""<header>
<h2>$page_title</h2>
<p>$count_total packages have been attempted to be build so far, that's
$percent_total% of $amount source packages in Debian sid
currently. Out of these, $count_good packagea ($percent_good%)
<a href="https://wiki.debian.org/ReproducibleBuilds">could be built
reproducible!</a></p>
<ul>
    <li>Have a look at:</li>
    <li>
        <a href="/userContent/index_reproducible.html" target="_parent">
        <img src="/userContent/static/weather-clear.png"
                                                alt="reproducible icon" /></a>
    </li>
    <li>
        <a href="/userContent/index_FTBR_with_buildinfo.html" target="_parent">
        <img src="/userContent/static/weather-showers-scattered.png"
                                        alt="FTBR_with_buildinfo icon" /></a>
    </li>
    <li>
        <a href="/userContent/index_FTBR.html" target="_parent">
        <img src="/userContent/static/weather-showers.png" alt="FTBR icon" />
        </a>
    </li>
    <li>
        <a href="/userContent/index_FTBFS.html" target="_parent">
        <img src="/userContent/static/weather-storm.png" alt="FTBFS icon" />
        </a>
    </li>
    <li>
        <a href="/userContent/index_404.html" target="_parent">
        <img src="/userContent/static/weather-severe-alert.png"
                                                    alt="404 icon" /></a>
    </li>
    <li>
        <a href="/userContent/index_not_for_us.html" target="_parent">
        <img src="/userContent/static/weather-few-clouds-night.png"
                                            alt="not_for_us icon" /></a>
    </li>
    <li>
        <a href="/userContent/index_blacklisted.html" target="_parent">
            <img src="/userContent/static/error.png" alt="blacklisted icon" />
        </a>
    </li>
    <li><a href="/userContent/index_issues.html">issues</a></li
    <li><li><a href="/userContent/index_notes.html">packages with notes</a></li></li>
    <li><a href="/userContent/index_scheduled.html">currently scheduled</a></li>
    <li><a href="/userContent/index_last_24h.html">packages tested in the last
                                                            24h</a></li>
    <li><a href="/userContent/index_last_48h.html">packages tested in the last
                                                                48h</a></li>
    <li><a href="/userContent/index_all_abc.html">all tested packages (sorted
                                                    alphabetically)</a></li>
    <li><a href="/userContent/index_dd-list.html">maintainers of unreproducible
                                                            packages</a></li>
    <li><a href="/userContent/index_stats.html">stats</a></li>
    <li><a href="/userContent/index_pkg_sets.html">package sets stats</a></li>
</ul></header>""")

html_foot_page = Template("""
<p style="font-size:0.9em;">A package name displayed with a bold font is an 
indication that this package has a note. Visited packages are linked in green,
those which have not been visited are linked in blue.</p>""")


url2html = re.compile(r'((mailto\:|((ht|f)tps?)\://|file\:///){1}\S+)')


def write_html_page(title, body, destfile, noheader=False, nofooter=False):
    now = datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')
    html = ''
    html += html_header.substitute(page_title=title)
    if not noheader:
        html += html_head_page.substitute(
            page_title=title,
            count_total=count_total,
            amount=amount,
            percent_total=percent_total,
            count_good=count_good,
            percent_good=percent_good)
    html += body
    if not nofooter:
        html += html_foot_page.substitute()
    html += html_footer.substitute(date=now)
    os.makedirs(destfile.rsplit('/', 1)[0], exist_ok=True)
    with open(destfile, 'w') as fd:
        fd.write(html)

def init_conn():
    return sqlite3.connect(REPRODUCIBLE_DB)

def query_db(query):
    cursor = conn.cursor()
    cursor.execute(query)
    return cursor.fetchall()

# do the db querying
conn = init_conn()
amount = int(query_db('SELECT count(name) FROM sources')[0][0])
count_total = int(query_db('SELECT COUNT(name) FROM source_packages')[0][0])
count_good = int(query_db(
 'SELECT COUNT(name) FROM source_packages WHERE status="reproducible"')[0][0])
percent_total = round(((count_total/amount)*100), 2)
percent_good = round(((count_good/count_total)*100), 2)
logging.info('Total packages in Sid:\t' + str(amount))
logging.info('Total tested packages:\t' + str(count_total))
logging.info('Total reproducible packages:\t' + str(count_good))
logging.info('That means that out of the ' + str(percent_total) + '% of ' +
             'the Sid tested packages the ' + str(percent_good) + '% are ' +
             'reproducible!')


