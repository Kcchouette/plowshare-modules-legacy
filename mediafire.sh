#!/bin/bash
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_MEDIAFIRE_REGEXP_URL="http://\(www\.\)\?mediafire\.com/"
MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS=""
MODULE_MEDIAFIRE_UPLOAD_OPTIONS=
MODULE_MEDIAFIRE_LIST_OPTIONS=
MODULE_MEDIAFIRE_DOWNLOAD_CONTINUE=no

# Output a mediafire file download URL
# $1: MEDIAFIRE_URL
# stdout: real file download link
mediafire_download() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1
    COOKIESFILE=$(create_tempfile)
    PAGE=$(curl -L -c $COOKIESFILE "$URL" | sed "s/>/>\n/g")
    COOKIES=$(< $COOKIESFILE)
    rm -f $COOKIESFILE

    test "$PAGE" || return 254

    if matchi 'Invalid or Deleted File' "$PAGE"; then
        log_debug "invalid or deleted file"
        return 254
    fi

    if test "$CHECK_LINK"; then
        match 'class="download_file_title"' "$PAGE" && return 255 || return 1
    fi

    FILE_URL=$(get_ofuscated_link "$PAGE" "$COOKIES") ||
        { log_error "error running Javascript code"; return 1; }

    echo "$FILE_URL"
}

get_ofuscated_link() {
    local PAGE=$1
    local COOKIES=$2
    BASE_URL="http://www.mediafire.com"

    detect_javascript >/dev/null || return 1

    FUNCTIONS=$(echo "$PAGE" | grep -o "function [[:alnum:]]\+[[:space:]]*(qk" |
                sed -n 's/^.*function[[:space:]]\+\([^(]\+\).*$/\1/p')
    test "$FUNCTIONS" ||
        { log_error "get_ofuscated_links: error getting JS functions"; return 1; }
    JSCODE=$(echo "$PAGE" | sed "s/;/;\n/g" |
             sed -n '/Eo[[:space:]]*();/,/^var jc=Array();/p' |
             tail -n"+2" | head -n"-2" | tr -d '\n')
    test "$JSCODE" ||
        { log_error "get_ofuscated_links: error getting JS code"; return 1; }
    JS_CALL=$({
        for FUNCTION in $FUNCTIONS; do
            echo "function $FUNCTION(qk, pk, r) {
                  print('$FUNCTION' + ',' + qk + ',' + pk + ',' + r); }"
        done
        echo $JSCODE
    } | javascript) ||
        { log_error "get_ofuscated_links: error running main JS code"; return 1; }
    IFS="," read FUNCTION QK PK R < <(echo "$JS_CALL" | tr -d "'")
    test "$FUNCTION" -a "$QK" -a "$PK" -a "$R" ||
        { log_error "get_ofuscated_links: error getting query variables"; return 1; }
    log_debug "function: $FUNCTION"
    JS_URL="$BASE_URL/dynamic/download.php?qk=$QK&pk=$PK&r=$R"
    log_debug "Javascript URL: $JS_URL"
    JS_CODE=$(curl -b <(echo "$COOKIES") "$JS_URL")
    #echo "$PAGE" > page.html; echo "$JS_CODE" > page.js
    JS_CODE2=$(echo "$PAGE" | sed "s/;/;\n/g" | grep "function $FUNCTION" -A13 | sed "s/^[[:space:]]*}}//") ||
        { log_error "get_ofuscated_links: error getting JS_CODE2"; return 1; }
    DIVID=$(echo "
        document = {getElementById: function(x) { print(x); return {'style': ''};}}
        function aa(x, y) {}
        StartDownloadTried = '0';
        $JS_CODE2 }}
        $FUNCTION('$QK', '$PK', '$R');" | javascript | sed -n 2p) ||
        { log_error "get_ofuscated_links: error getting DIV id"; return 1; }
    log_debug "divid: $DIVID"
    {
        echo "
          var d = {'innerHTML': ''};
          parent = {
            document: {'getElementById': function(x) {
                print('divid:' + x);
                print(d.innerHTML);
                return d;
              }
            },
          };
        "
        echo "$JS_CODE" | tail -n "+2" | head -n "-1"
        echo "dz();"
    } | javascript | grep "divid:$DIVID" -A3 | tail -n1 | parse "href" 'href="\(.*\)"'
}

# List a mediafire shared file folder URL
# $1: MEDIAFIRE_URL (http://www.mediafire.com/?sharekey=...)
# stdout: list of links
mediafire_list() {
    set -e
    eval "$(process_options mediafire "$MODULE_MEDIAFIRE_LIST_OPTIONS" "$@")"
    URL=$1

    PAGE=$(curl "$URL" | sed "s/>/>\n/g")

    match '/js/myfiles.php/' "$PAGE" ||
        { log_error "not a shared folder"; return 1; }

    local JS_URL=$(echo "$PAGE" | parse 'language=' 'src="\(\/js\/myfiles\.php\/[^"]*\)')
    local DATA=$(curl "http://mediafire.com$JS_URL" | sed "s/;/;\n/g")

    # get number of files
    NB=$(echo "$DATA" | parse '^var oO' "'\([[:digit:]]*\)'")
    NB2=$NB

    log_debug "There is $NB file(s) in the folder"

    # First pass : print debug message
    # es[0]=Array('1','1',3,'te9rlz5ntf1','82de6544620807bf025c12bec1713a48','my_super_file.txt','14958589','14.27','MB','43','02/13/2010', ...
    while [[ "$NB" -gt 0 ]]; do
        ((NB--))
        LINE=$(echo "$DATA" | parse "es\[$NB\]=" "Array(\(.*\));")
        FILENAME=$(echo "$LINE" | cut -d, -f6 | tr -d "'")
        log_debug "$FILENAME"
    done

    # Second pass : print links (stdout)
    NB=$NB2
    while [[ "$NB" -gt 0 ]]; do
        ((NB--))
        LINE=$(echo "$DATA" | parse "es\[$NB\]=" "Array(\(.*\));")
        FID=$(echo "$LINE" | cut -d, -f4 | tr -d "'")
        echo "http://www.mediafire.com/?$FID"
    done

    return 0
}
