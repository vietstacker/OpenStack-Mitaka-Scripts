#!/bin/bash -ex
#
# RABBIT_PASS=
# ADMIN_PASS=

source config.cfg
source functions.sh

# echocolor "Configuring net forward for all VMs"
# sleep 5
# echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
# echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
# echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf
# sysctl -p


#####################################################
echocolor "Create DB for HEAT "
sleep 5

neutrondb_present=$(mysql -uroot -p$MYSQL_PASS -e "
SHOW DATABASES LIKE 'heat';
")

if [ -z "$neutrondb_present" ]; then
  cat << EOF | mysql -uroot -p$MYSQL_PASS
  CREATE DATABASE heat;
  GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$HEAT_DBPASS';
  GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$HEAT_DBPASS';
  FLUSH PRIVILEGES;
EOF
fi


######################################################
echocolor "Create  user, endpoint for HEAT"
sleep 5

endpoints=$(openstack endpoint list | grep heat) || true

if [ -z "$endpoints" ]; then
  openstack user create heat --domain default --password $HEAT_PASS
  openstack role add --project service --user heat admin
  openstack service create --name heat --description "Orchestration" orchestration
  openstack service create --name heat-cfn --description "Orchestration" cloudformation
  openstack endpoint create --region RegionOne orchestration public   http://$CTL_MGNT_IP:8004/v1/%\(tenant_id\)s
  openstack endpoint create --region RegionOne orchestration internal http://$CTL_MGNT_IP:8004/v1/%\(tenant_id\)s
  openstack endpoint create --region RegionOne orchestration admin    http://$CTL_MGNT_IP:8004/v1/%\(tenant_id\)s

  openstack endpoint create --region RegionOne cloudformation public   http://$CTL_MGNT_IP:8000/v1
  openstack endpoint create --region RegionOne cloudformation internal http://$CTL_MGNT_IP:8000/v1
  openstack endpoint create --region RegionOne cloudformation admin    http://$CTL_MGNT_IP:8000/v1

  openstack domain create --description "Stack projects and users" heat
  openstack user create --domain heat --password-prompt heat_domain_admin
  openstack role add --domain heat --user-domain heat --user heat_domain_admin admin
  openstack role create heat_stack_owner
  openstack role add --project demo --user demo heat_stack_owner

  openstack role create heat_stack_user
fi


# SERVICE_TENANT_ID=`keystone tenant-get service | awk '$2~/^id/{print $4}'`


#######################################################
echocolor "Install HEAT"
sleep 5
apt-get -y install heat-api heat-api-cfn heat-engine


######## Backup configuration NEUTRON.CONF ##################"
echocolor "Config HEAT"
sleep 5

#
heat_ctl=/etc/heat/heat.conf
test -f $heat_ctl.orig || cp $heat_ctl $heat_ctl.orig

## [DEFAULT] section

ops_edit $heat_ctl DEFAULT rpc_backend rabbit
ops_edit $heat_ctl DEFAULT heat_metadata_server_url http://$CTL_MGNT_IP:8000
ops_edit $heat_ctl DEFAULT heat_waitcondition_server_url http://$CTL_MGNT_IP:8000/v1/waitcondition
ops_edit $heat_ctl DEFAULT stack_domain_admin heat_domain_admin
ops_edit $heat_ctl DEFAULT stack_domain_admin_password $HEAT_PASS
ops_edit $heat_ctl DEFAULT stack_user_domain_name heat

## [database] section
ops_edit $heat_ctl database \
connection mysql+pymysql://heat:$HEAT_DBPASS@$CTL_MGNT_IP/heat


## [keystone_authtoken] section
ops_edit $heat_ctl keystone_authtoken auth_uri http://$CTL_MGNT_IP:5000
ops_edit $heat_ctl keystone_authtoken auth_url http://$CTL_MGNT_IP:35357
ops_edit $heat_ctl keystone_authtoken memcached_servers $CTL_MGNT_IP:11211
ops_edit $heat_ctl keystone_authtoken auth_type password
ops_edit $heat_ctl keystone_authtoken project_domain_name default
ops_edit $heat_ctl keystone_authtoken user_domain_name default
ops_edit $heat_ctl keystone_authtoken project_name service
ops_edit $heat_ctl keystone_authtoken username heat
ops_edit $heat_ctl keystone_authtoken password $HEAT_PASS

## [trustee] section
ops_edit $heat_ctl trustee auth_plugin password
ops_edit $heat_ctl trustee auth_url http://$CTL_MGNT_IP:35357
ops_edit $heat_ctl trustee username heat
ops_edit $heat_ctl trustee password $HEAT_PASS
ops_edit $heat_ctl trustee user_domain_name default

## [clients_keystone] section
ops_edit $heat_ctl clients_keystone auth_uri http://$CTL_MGNT_IP:35357

## [ec2authtoken] section
ops_edit $heat_ctl ec2authtoken auth_uri http://$CTL_MGNT_IP:5000

## [oslo_messaging_rabbit] section
ops_edit $heat_ctl oslo_messaging_rabbit rabbit_host $CTL_MGNT_IP
ops_edit $heat_ctl oslo_messaging_rabbit rabbit_userid openstack
ops_edit $heat_ctl oslo_messaging_rabbit rabbit_password $RABBIT_PASS



su -s /bin/sh -c "heat-manage db_sync" heat

echocolor "Restarting HEAT services"
sleep 7
service heat-api restart
service heat-api-cfn restart
service heat-engine restart

echocolor "Finished install HEAT on CONTROLLER"


