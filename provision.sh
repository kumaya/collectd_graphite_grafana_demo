#!/bin/bash

# disable auto updates
systemctl stop apt-daily.timer
systemctl disable apt-daily.timer
systemctl mask apt-daily.service
systemctl daemon-reload
mv /usr/lib/apt/apt.systemd.daily /usr/lib/apt/apt.systemd.daily.DISABLED
systemctl stop apt-daily.service
systemctl kill --kill-who=all apt-daily.service

# wait until `apt-get updated` has been killed
while ! (systemctl list-units --all apt-daily.service | fgrep -q dead)
do
  sleep 1;
done

apt-get clean
apt-get -f install -y
apt-get install -y apt-transport-https
apt-get update

# Graphite
export DEBIAN_FRONTEND=noninteractive
apt-get install -y postgresql
apt-get install -y --force-yes graphite-carbon
apt-get install -y graphite-web libpq-dev python-psycopg2

# Configure Django database.
# Local box, assume that person on the box is trusted.
POSTGRES_VERSION=`ls /etc/postgresql/`
sed -i "s|peer|trust|" /etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf
service postgresql restart
psql --username=postgres -c "CREATE USER graphite WITH PASSWORD 'password';"
psql --username=postgres -c "CREATE DATABASE graphite WITH OWNER graphite;"

# Configure Graphite web app
# Use the default values in the config file.
CONFIG=/etc/graphite/local_settings.py
for v in SECRET_KEY TIME_ZONE USE_REMOTE_USER_AUTHENTICATION; do
    sed -i "s|#${v}|${v}|" $CONFIG
done

sed -i "s/'NAME'.*/'NAME': 'graphite',/" $CONFIG
sed -i "s/'ENGINE'.*/'ENGINE': 'django.db.backends.postgresql_psycopg2',/" $CONFIG
sed -i "s/'USER': ''/'USER': 'graphite'/" $CONFIG
sed -i "s/'PASSWORD': ''/'PASSWORD': 'password'/" $CONFIG
sed -i "s/'HOST': ''/'HOST': '127.0.0.1'/" $CONFIG

# sync the database.
# Ref http://stackoverflow.com/questions/1466827/
graphite-manage migrate auth --noinput
graphite-manage migrate --noinput
graphite-manage syncdb --noinput
# Create superuser, account/password admin/admin.
echo "from django.contrib.auth.models import User; User.objects.create_superuser('admin', 'admin@example.com', 'admin')" | graphite-manage shell

# Configure Carbon
sed -i 's/CARBON_CACHE_ENABLED=false/CARBON_CACHE_ENABLED=true/' /etc/default/graphite-carbon
sed -i 's/ENABLE_LOGROTATION.*/ENABLE_LOGROTATION = True/' /etc/carbon/carbon.conf
sed -i 's/\[default_1min/[test] \
pattern = ^test\\. \
retentions = 10s:10m,1m:1h,10m:1d \
 \
[default_1min/' /etc/carbon/storage-schemas.conf
cp /usr/share/doc/graphite-carbon/examples/storage-aggregation.conf.example \
   /etc/carbon/storage-aggregation.conf
service carbon-cache start

# Install and configure Apache
apt-get install -y apache2 libapache2-mod-wsgi
a2dissite 000-default
cp /usr/share/graphite-web/apache2-graphite.conf /etc/apache2/sites-available
a2ensite apache2-graphite
service apache2 reload

# Add some test data
for v in 1 2 3; do
    echo "Adding data point ${v}"
    echo "test.count 4 `date +%s`" | nc -q0 127.0.0.1 2003
    sleep 10
done

# Collectd
modprobe nf_conntrack   # "read-function of plugin `conntrack' failed"
apt-get install -y collectd collectd-utils
sed -i 's/#Hostname.*/Hostname "graph_host"/' /etc/collectd/collectd.conf
for x in apache cpu df entropy interface load memory uptime\
        processes rrdtool users write_graphite conntrack; do
    echo $x
    sed -i "s|#LoadPlugin ${x}|LoadPlugin ${x}|" /etc/collectd/collectd.conf
done
DEVICE=`df | grep ^/dev | awk '{ print $1 }'`
cat <<EOF >> /etc/collectd/collectd.conf

<Plugin apache>
    <Instance "Graphite">
        URL "http://http://192.168.33.10//server-status?auto"
        Server "apache"
    </Instance>
</Plugin>

<Plugin df>
    Device "${DEVICE}"
    MountPoint "/"
    FSType "ext3"
</Plugin>

<Plugin interface>
    Interface "lo"
    IgnoreSelected true
</Plugin>

<Plugin write_graphite>
    <Node "graphing">
        Host "localhost"
        Port "2003"
        Protocol "tcp"
        LogSendErrors true
        Prefix "collectd."
        StoreRates true
        AlwaysAppendDS false
        EscapeCharacter "_"
    </Node>
</Plugin>
EOF

# Apache stats recording
sed -i 's|^.*ErrorLog| \
        <Location "/server-status"> \
                SetHandler server-status \
                Require all granted \
        </Location> \
 \
        ErrorLog|' /etc/apache2/sites-available/apache2-graphite.conf
service apache2 reload

sed -i 's/\[default_1min/[collectd] \
pattern = ^collectd.* \
retentions = 10s:1d,1m:7d,10m:1y \
 \
[default_1min/' /etc/carbon/storage-schemas.conf

service carbon-cache stop
sleep 2  # wait for data flush.
service carbon-cache start

service collectd stop
service collectd start

# Grafana
wget https://s3-us-west-2.amazonaws.com/grafana-releases/release/grafana_5.2.4_amd64.deb
dpkg -i grafana_5.2.4_amd64.deb
rm grafana_5.2.4_amd64.deb
setcap 'cap_net_bind_service=+ep' /usr/sbin/grafana-server
update-rc.d grafana-server defaults 95 10
service grafana-server start
umask 226 && echo "vagrant ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vagrant_user