#!/bin/sh

LOGIN_TOKEN='xxxxxxxxx,xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
DOMAIN_ID='xxxxxxxx'
RECERD_ID='xxxxxxxxxxxx'
SUB_DOMAIN='xxxxxxxxx'

RECERD_TYPE='AAAA'
IPv4='127.0.0.1'
IPv6='fe80::a60:6eff:fe7a:51ae'
IPv6=`ip addr show enp3s0 | grep "inet6.2409" | awk '{print $2}' | awk -F"/" '{print $1}'| head -1`

POST_JSON="login_token=$LOGIN_TOKEN&format=json&domain_id=$DOMAIN_ID&record_id=$RECERD_ID&record_line_id=0&sub_domain=$SUB_DOMAIN&value=$IPv6&record_type=$RECERD_TYPE"

oldIPv6=`cat /var/log/ddns.db`
UpdateFlage=`cat /var/log/ddns.flage`
HOSTNAME=`host gzhome.gdberry.cn`

echo "UpdateTime:" $UpdateFlage "min"
echo $HOSTNAME
echo "oldIPv6:" $oldIPv6
echo "newIPv6:" $IPv6

if [ "$IPv6"x = "$oldIPv6"x ] && [ $UpdateFlage -lt 60 ];then
    echo "newIP = oldIP, don't update"
    count=$(expr $UpdateFlage + 1)
    echo $count > /var/log/ddns.flage
else
    echo "0" > /var/log/ddns.flage
    echo "update"
    echo $IPv6 > /var/log/ddns.db
    curl -X POST https://dnsapi.cn/Record.Modify -d "$POST_JSON"
    echo ""
fi
