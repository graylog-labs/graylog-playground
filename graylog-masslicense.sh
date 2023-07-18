#!/bin/bash
licensefile="license.json"
numlicenses=$(jq '. | length' $licensefile)
if [ $numlicenses -gt 0 ]
then
    for ((i = 0; i < $numlicenses; i++ ))
    do
        host=$(jq -r ".[$i].host" $licensefile)
        echo $host
        license=$(jq -r ".[$i].license" $licensefile)
        if [ $(jq ".[$i] | has(\"userpass\")" $licensefile) == "true" ]
        then
            gl_userpass=$(jq -r ".[$i].userpass" $licensefile)
            curl -u $gl_userpass "$host/api/plugins/org.graylog.plugins.license/licenses" -H 'Content-Type: application/json' -H 'X-Requested-By: PS_TeamAwesome' -d "$license"
        elif [ $(jq ".[$i] | has(\"token\")" $licensefile) == "true" ]
        then
            gl_token=$(jq -r ".[$i].token" $licensefile)
            curl -u "$gl_token:token" "$host/api/plugins/org.graylog.plugins.license/licenses" -H 'Content-Type: application/json' -H 'X-Requested-By: PS_TeamAwesome' -d "$license"
        else
            echo "ERROR: No credential found"
        fi
        unset host
        unset gl_userpass
        unset gl_token
    done
fi