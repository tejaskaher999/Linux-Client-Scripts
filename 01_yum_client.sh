#!/bin/bash

# Variables Which Can Any System Admin Change As Per Their Need!
HTTP_PATH=/var/www/html/rhel
PACKAGE_NAME=("AppStream" "BaseOS")
REPO_CONFIG_PATH=/etc/yum.repos.d/local.repo

touch $REPO_CONFIG_PATH

# Get a user input from user to store the $USER_SERVER_IP from which user can use its local RPM / YUM / DNF.
USER_SERVER_IP

# Creating Repo File With It's Content
# Looping Through Package Names To Create Repo File
for i in "${PACKAGE_NAME[@]}";
do
    echo "[${i}]" >> $REPO_CONFIG_PATH
    echo "name=${i}" >> $REPO_CONFIG_PATH
    echo "baseurl=http://$USER_SERVER_IP/$HTTP_PATH/${i}" >> $REPO_CONFIG_PATH
    echo "gpgcheck=0" >> $REPO_CONFIG_PATH
    echo "metadata_expire=-1" >> $REPO_CONFIG_PATH
    echo "enabled=1" >> $REPO_CONFIG_PATH
    echo "" >> $REPO_CONFIG_PATH
done

# Set Up & Check Repos
dnf clean all
dnf repolist all -v

echo "You can now install softwares using:"
echo "dnf install <rpm_name>"
