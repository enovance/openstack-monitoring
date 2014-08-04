#!/bin/bash

# Nova API monitoring script for Sensu / Nagios
#
# Copyright © 2013-2014 eNovance <licensing@enovance.com>
#
# Author: Emilien Macchi <emilien.macchi@enovance.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Requirement: curl, bc
#
set -e

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

usage ()
{
    echo "Usage: $0 [OPTIONS]"
    echo " -h                   Get help"
    echo " -H <Auth URL>        URL for obtaining an auth token. Ex: http://localhost:5000/v2.0"
    echo " -E <Endpoint URL>    URL for nova API. Ex: http://localhost:8774/v2"
    echo " -T <tenant>          Tenant to use to get an auth token"
    echo " -U <username>        Username to use to get an auth token"
    echo " -P <password>        Password to use ro get an auth token"
}

while getopts 'hH:U:T:P:E:' OPTION
do
    case $OPTION in
        h)
            usage
            exit 0
            ;;
        H)
            export OS_AUTH_URL=$OPTARG
            ;;
        E)
            export ENDPOINT_URL=$OPTARG
            ;;
        T)
            export OS_TENANT_NAME=$OPTARG
            ;;
        U)
            export OS_USERNAME=$OPTARG
            ;;
        P)
            export OS_PASSWORD=$OPTARG
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

INSECURE=""

if [[ $OS_AUTH_URL =~ https.* ]]; then
    INSECURE="--insecure"
fi

# Set default values
OS_AUTH_URL=${OS_AUTH_URL:-"http://localhost:5000/v2.0"}
ENDPOINT_URL=${ENDPOINT_URL:-"$(keystone $INSECURE catalog --service compute|grep publicURL|cut -d'|' -f3|sed 's/\s*//g')"}

if ! which curl >/dev/null 2>&1
then
    echo "curl is not installed."
    exit $STATE_UNKNOWN
fi

if ! which bc >/dev/null 2>&1
then
    echo "bc is not installed."
    exit $STATE_UNKNOWN
fi

# Get a token from Keystone
TOKEN=$(curl $INSECURE -s -X 'POST' ${OS_AUTH_URL}/tokens -d '{"auth":{"passwordCredentials":{"username": "'$OS_USERNAME'", "password":"'$OS_PASSWORD'"}, "tenantName":"'$OS_TENANT_NAME'"}}' -H 'Content-type: application/json' |python -c 'import sys; import json; data = json.loads(sys.stdin.readline()); print data["access"]["token"]["id"]')

if [ -z "$TOKEN" ]; then
    echo "Unable to get a token from Keystone API"
    exit $STATE_CRITICAL
fi

#Get the tenant ID
#TENANT_ID=$(curl $INSECURE -s -H "X-Auth-Token: $TOKEN" ${OS_AUTH_URL}/tenants |python -c 'import sys; import json; data = json.loads(sys.stdin.readline()); print data["tenants"][0]["id"]')
TENANT_ID=$(curl $INSECURE -s -H "X-Auth-Token: $TOKEN" ${OS_AUTH_URL}/tenants |python -c 'import sys; import json; data = json.loads(sys.stdin.readline()); print [i.get("id") for i in data.get("tenants") if i.get("name") == "Infrastructure"][0]')
if [ -z $TENANT_ID ]
then
	output_result "CRITICAL - Unable to get tenant ID from Keystone API" $STATE_CRITICAL
fi

START=`date +%s.%N`
SERVICES=$(curl $INSECURE -X GET -s -H "X-Auth-Token: $TOKEN" "${ENDPOINT_URL}"/os-services)
SERVICES_UP=$(echo $SERVICES | python -c 'import sys; import json; data = json.loads(sys.stdin.readline()); print [ i for i in data.get("services") if i.get("status") == "enabled" and i.get("state") == "up" ]')
SERVICES_DOWN=$(echo $SERVICES | python -c 'import sys; import json; data = json.loads(sys.stdin.readline()); print [ i for i in data.get("services") if i.get("status") == "enabled" and i.get("state") != "up" ]')
END=`date +%s.%N`

TIME=`echo ${END} - ${START} | bc`

if [ "$SERVICES_DOWN" != "[]" ]; then
    echo "$SERVICES_DOWN"
    exit $STATE_CRITICAL
fi


if [ `echo ${TIME}'>'10 | bc -l` -gt 0 ]; then
     echo "Got services list after 10 seconds, it's too long.|response_time=${TIME}"
     exit $STATE_WARNING
else
    SERVICES_UP_STR=$(echo "$SERVICES" | python -m json.tool)
    echo "Get services list (response_time:${TIME}). $SERVICES_UP_STR"
    exit $STATE_OK
fi
