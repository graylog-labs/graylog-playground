#!/bin/bash
# NAME
#    Speedtest to GELF Script

# SYNOPSIS
#    Builds a GELF message from the results of speedtest and sends to graylog in GELF input 

# DESCRIPTION
#    Runs speedtest, ouput to JOSN. Using GRON to grab required data, make changes (human readable), update timestamp for GELF format and
#    outputs entire new GELF message to passed server($1) and port($2) 


# PREREQUISITES
#    Speedtest, NC, GRON and a functional graylog instance with a GELF input

# RELATED LINKS
#    Public graylog tools repo: https:#github.com/graylog-labs/graylog-playground
#    graylog Documentation:     https:#go2docs.graylog.org
#    graylog Technical Support: https:#www.graylog.org/technical-support/
#    Speedtest:                 https://speedtest.net
#    GRON man:                  https://www.mankier.com/1/gron
#    NetCat man:                https://linux.die.net/man/1/nc

# AUTHOR
#    Name: Dan McDowell
#    Department: Graylog Professional Services
#    Contact: enablement@graylog.com

# VERSION
#    Number: 1.0
#    Date: 03-13-2023

gelf="{
\"version\": \"1.1\","
gelf=$(echo -e "$gelf\n \"short_message\": \"Speed Test Results\",\n")

result=$(speedtest --accept-license -f json)
fjson=$(echo $result | gron | cut -c 6- | sed '/{};/d' | tr -d '"' | tr -d ';')
echo -e "$fjson" | while IFS= read -r line
do
        field=$(echo $line | awk -F '=' '{print $1}' | sed 's/\./_/g' | sed 's/^ *//g' | sed 's/ *$//g')
        data=$(echo $line | awk -F '=' '{print $2}' | sed 's/^ *//g' | sed 's/ *$//g')
        #Convert to useful Mbps
        if [[ "$line" == *"bandwidth"* ]]; then
                data=$(($data/125000))
        fi
        #Convert Bytes to MB
        if [[ "$line" == *"bytes"* ]]; then
                data=$(($data/1024/1024))
                field=$(echo $field | sed 's/bytes/megabytes/g')
        fi
        #Convert Timestamp for Grok
        if [[ "$line" == *"timestamp"* ]]; then
                data=$(date -d $(echo $data | tr -d '"' | sed 's@\\@@g') +"%s")
        fi

        #Don't wrap numbers!
        if [[ $data =~ ^[0-9]*(\.[0-9]+)?$ ]]; then
                #Don't Wrap Numbers
                gelf=$(echo -e "$gelf\n \"$field\": $data,\n")
        else
                #Wrap Strings
                gelf=$(echo -e "$gelf\n \"$field\": \"$data\",\n")
        fi
        echo -e "$gelf" > ./gelf.tmp
done
gelf=$(cat ./gelf.tmp)
rm ./gelf.tmp
gelf=${gelf%?}
gelf=$(echo -e "$gelf\n}")
echo -e "$gelf" > ./gelf.tmp
echo $gelf | ncat -w 1 $1 $2
