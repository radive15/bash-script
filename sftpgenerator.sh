#!/bin/bash

export merchant_ID=$1
mkdir -p /metadata/sftp/mct_settle/$1/download/settlement
sudo useradd -d /metadata/sftp/mct_settle/$1/download/settlement -s /usr/bin/rssh $1
sudo sh -c "echo \"user=$1:011:00010:/metadata/sftp/mct_settle/$1/download/settlement\" >> /etc/rssh.conf"
/home/admin/diqing/randpwd.sh > ~/diqing/$1
cat $1 | sudo passwd $1 --stdin
sudo sh -c "echo \"$1=/metadata/sftp/mct_settle/$1\" >> /metadata/sftp/bin/sync.conf"
sudo cp -r /home/admin/CHROOT/* /metadata/sftp/mct_settle/$1/download/settlement
sudo sh /metadata/sftp/bin/sync.sh
echo done
