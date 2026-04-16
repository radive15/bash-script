#!/bin/bash -x

domain="k8s.local"
zone="Z0027769AL6VVCOQ6GCX"
binAWS="/usr/bin/aws"
getMetadataName="$($binAWS ec2 describe-tags --filters "Name=resource-id,Values=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)" --query 'Tags[*].Value' --output text)"
subDomain="`echo $getMetadataName | cut -d '.' -f 1`"
hostname=$getMetadataName
homeDir="/home/centos"
privateIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

#Set Hostname
sed -i "s/^\(HOSTNAME\s*=\s*\).*$/\1$hostname/" /etc/sysconfig/network
hostnamectl set-hostname --static $hostname
echo $hostname > /etc/hostname
sed -i 's/ - set_hostname/\#- set_hostname/' /etc/cloud/cloud.cfg
sed -i 's/ - update_hostname/\#- update_hostname/' /etc/cloud/cloud.cfg
echo "127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4 localhost.$domain
::1       localhost localhost.localdomain localhost6 localhost6.localdomain6

$privateIP $hostname $subDomain" > /etc/hosts

#Set DNS

getSubDomain=$(cli53 export $zone | grep -w $privateIP | grep $subDomain | head -n1 | awk '{print $1}')
if [ "$getSubDomain" == "$subDomain" ]; then
  cli53 rrdelete $zone $getSubDomain A
  cli53 rrcreate $zone "$subDomain 60 A $privateIP"
else
  sudo cli53 rrcreate $zone "$subDomain 60 A $privateIP"
fi
