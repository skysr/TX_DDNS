#!/bin/bash

LOGIN_TOKEN='xxxxxxxxx,xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
DOMAIN_ID='xxxxxxxx'
RECORD_ID='xxxxxxxxxxxx'
SUB_DOMAIN='xxxxxxxxx'

RECORD_TYPE='AAAA'
IPv6='fe80::a60:6eff:fe7a:51ae'
IPv6=`ip addr show enp3s0 | grep "inet6.2409" | awk '{print $2}' | awk -F"/" '{print $1}'| head -1`

POST_JSON="login_token=$LOGIN_TOKEN&format=json&domain_id=$DOMAIN_ID&record_id=$RECORD_ID&record_line_id=0&sub_domain=$SUB_DOMAIN&value=$IPv6&record_type=$RECORD_TYPE"

oldIPv6=`cat /var/log/ddns.db`
UpdateFlag=`cat /var/log/ddns.flag`
HOSTNAME=`host gzhome.gdberry.cn`

echo "UpdateTime:" $UpdateFlag "min"
echo $HOSTNAME
echo "oldIPv6:" $oldIPv6
echo "newIPv6:" $IPv6

if [ "$IPv6"x = "$oldIPv6"x ] && [ $UpdateFlag -lt 60 ];then
    echo "newIP = oldIP, don't update"
    count=$(expr $UpdateFlag + 1)
    echo $count > /var/log/ddns.flag
else
    echo "0" > /var/log/ddns.flag
    echo "update"
    echo $IPv6 > /var/log/ddns.db
    curl -X POST https://dnsapi.cn/Record.Modify -d "$POST_JSON"
    echo ""
fi
