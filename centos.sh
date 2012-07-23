#!/bin/bash -e

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root user."
    exit 1
fi

mach=`uname -m`
if [[ "$mach" != "x86_64" ]]; then
    echo "64-bit installer only"
fi

locale | grep "LANG" | grep -i "UTF.*8"
status=$?
if [[ "$status" != "0" ]]; then
    echo "Invalid locale. Must be UTF-8. Exiting.."
    exit 1
fi


function randpass() {
  [ "$2" == "0" ] && CHAR="[:alnum:]" || CHAR="[:graph:]"
    cat /dev/urandom | tr -cd "$CHAR" | head -c ${1:-32}
    echo
}


function uninstall() {
    set +e
    
    #python /tmp/airtime-2.1.3/python_apps/media-monitor/install/media-monitor-copy-files.py
    #python /tmp/airtime-2.1.3/python_apps/media-monitor/install/media-monitor-initialize.py
    #python /tmp/airtime-2.1.3/python_apps/pypo/install/pypo-copy-files.py
    #python /tmp/airtime-2.1.3/python_apps/pypo/install/pypo-initialize.py
       
    echo "Uninstalling Zend"
    pear uninstall zend/zend
    
    echo "Uninstalling virtualenv"
    pip -q uninstall virtualenv
    
    pear channel-logout zend.googlecode.com/svn
    pear channel-delete zend.googlecode.com/svn
    
    echo "* Removing pypo user"
    userdel pypo
    userdel airtime
    
    echo "* Removing Airtime database"
    sudo -u postgres dropdb airtime
    sudo -u postgres dropuser airtime
    
    path="/usr/lib/airtime"
    echo "Removing $path"
    rm -rf "$path"

    path="/etc/httpd/conf.d/airtime.conf"
    echo "Removing $path"
    rm -rf "$path"
    
    path="/var/www/html/airtime"
    echo "Removing $path"
    rm -rf "$path"
    
    path="/etc/airtime"
    echo "Removing $path"
    rm -rf "$path"

    echo "Packages installed via yum will need to be removed manually."
    echo "Media library at /srv/airtime/stor must be removed manually."
    
    set -e
}

function install() {
    echo "Installing PHP package dependencies"
    yum -y install tar gzip curl php-pear postgresql python patch lsof sudo \
    postgresql-server httpd php-pgsql php-gd php wget

    echo "* Installing PHP Zend package"
    pear channel-discover zend.googlecode.com/svn
    pear install zend/zend

    echo "* Initializing Postgresql"
    set +e
    service postgresql initdb
    set -e
    service postgresql start

    #Allow remote access to httpd
    #iptables -I INPUT 5 -m tcp -p tcp --dport 80 -j ACCEPT

    echo "* Installing python-pip"
    curl http://python-distribute.org/distribute_setup.py | python
    curl https://raw.github.com/pypa/pip/master/contrib/get-pip.py | python

    echo "* Installing python virtualenv"
    pip install virtualenv

    echo "* Downloading Airtime 2.1.3"
    wget -O /tmp/airtime-2.1.3.tar.gz http://sourceforge.net/projects/airtime/files/2.1.3/airtime-2.1.3.tar.gz
    cd /tmp
    tar xzf airtime-2.1.3.tar.gz

    echo "* Creating Airtime virtualenv"
    /tmp/airtime-2.1.3/python_apps/python-virtualenv/virtualenv-install.sh


    #web files
    echo "* Configuring httpd"
    cp /tmp/airtime-2.1.3/install_full/apache/airtime-vhost /etc/httpd/conf.d/airtime.conf
    sed -i 's#DocumentRoot.*$#DocumentRoot /var/www/html/airtime/public#g' /etc/httpd/conf.d/airtime.conf
    sed -i 's#<Directory .*$#<Directory /var/www/html/airtime/public>#g' /etc/httpd/conf.d/airtime.conf

    echo "* Copying Airtime web files"
    mkdir -p /var/www/html/airtime
    cp -R /tmp/airtime-2.1.3/airtime_mvc/* /var/www/html/airtime

    mkdir -p /etc/airtime
    mkdir -p /srv/airtime/stor

    echo "* Creating Airtime Database"
    cp /tmp/airtime-2.1.3/airtime_mvc/build/airtime.conf /etc/airtime/airtime.conf
        
    echo "* Creating airtime user"
    adduser --system --user-group airtime

    CHAR="[:alnum:]"
    rand=`cat /dev/urandom | tr -cd "$CHAR" | head -c ${1:-32}`
    sed -i "s/api_key = .*$/api_key = $rand/g" /etc/airtime/airtime.conf

    sudo -u postgres psql -c "CREATE USER airtime ENCRYPTED PASSWORD 'airtime' LOGIN CREATEDB NOCREATEUSER;"
    sudo -u postgres createdb -O airtime --encoding UTF8 airtime

    cd /tmp/airtime-2.1.3/airtime_mvc/build/sql
    sudo -u airtime psql --file schema.sql airtime
    sudo -u airtime psql --file sequences.sql airtime
    sudo -u airtime psql --file views.sql airtime
    sudo -u airtime psql --file triggers.sql airtime
    sudo -u airtime psql --file defaultdata.sql airtime
    sudo -u airtime psql -c "INSERT INTO cc_pref (keystr, valstr) VALUES ('system_version', '2.1.3');"
    sudo -u airtime psql -c "INSERT INTO cc_music_dirs (directory, type) VALUES ('/srv/airtime/stor', 'stor');"

    sudo -u airtime psql -c "INSERT INTO cc_pref (keystr, valstr) VALUES ('timezone', 'UTC')"

    unique_id=`php -r "echo md5(uniqid('', true));"`
    sudo -u airtime psql -c "INSERT INTO cc_pref (keystr, valstr) VALUES ('uniqueId', '$unique_id')"
    sudo -u airtime psql -c "INSERT INTO cc_pref (keystr, valstr) VALUES ('import_timestamp', '0')"

    echo "* Allowing httpd to connect to postgresql (SELinux)"
    set +e
    setsebool -P httpd_can_network_connect_db 1
    set -e


    #change /var/lib/pgsql/data/pg_hba.conf
    #Change auth type to md5:
    echo "* Modifying /var/lib/pgsql/data/pg_hba.conf"
    sed -i 's#host.*$#host    all         all         127.0.0.1/32          md5#g' /var/lib/pgsql/data/pg_hba.conf
    sed -i 's#host.*$#host    all         all         ::1/128               md5#g' /var/lib/pgsql/data/pg_hba.conf

    echo "* Creating pypo user"
    adduser --system --user-group pypo


    echo "* Installing monit"
    #http://wiki.centos.org/AdditionalResources/Repositories/RPMForge/#head-f0c3ecee3dbb407e4eed79a56ec0ae92d1398e01
    #http://www.dullnicker.com/dnb/how-to-install-monit-on-centos-5-and-monitor-httpd/
    wget -O /tmp/rpmforge-release-0.5.2-2.el6.rf.x86_64.rpm http://packages.sw.be/rpmforge-release/rpmforge-release-0.5.2-2.el6.rf.x86_64.rpm
    set +e
    rpm --import http://apt.sw.be/RPM-GPG-KEY.dag.txt
    set -e
    rpm -K /tmp/rpmforge-release-0.5.2-2.el6.rf.x86_64.rpm
    rpm -i /tmp/rpmforge-release-0.5.2-2.el6.rf.x86_64.rpm || true
    
    yum -y install monit

    mkdir -p /etc/monit.d/
    mkdir -p /etc/monit/conf.d
    echo "include /etc/monit/conf.d/*" > /etc/monit.d/monitrc

    echo "* Installing RabbitMQ"
    #http://www.rabbitmq.com/install-rpm.html
    rpm -Uvh http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-7.noarch.rpm || true
    yum -y install erlang
    
    rpm -Uvh http://www.rabbitmq.com/releases/rabbitmq-server/v2.8.4/rabbitmq-server-2.8.4-1.noarch.rpm
    #service rabbitmq-server start
       
    locale | grep "LANG" > /etc/default/locale

    echo "* Installing Airtime services"
    python /tmp/airtime-2.1.3/python_apps/api_clients/install/api_client_install.py
    cp -R /tmp/airtime-2.1.3/python_apps/std_err_override /usr/lib/airtime

    python /tmp/airtime-2.1.3/python_apps/media-monitor/install/media-monitor-copy-files.py
    python /tmp/airtime-2.1.3/python_apps/media-monitor/install/media-monitor-initialize.py
    python /tmp/airtime-2.1.3/python_apps/pypo/install/pypo-copy-files.py
    
    #TODO remove dependency on debian liquidsoap 
    python /tmp/airtime-2.1.3/python_apps/pypo/install/pypo-initialize.py || true


    echo "* Installing Liquidsoap"
    yum -y install ocaml ocaml-findlib.x86_64 libao libao-devel libmad libmad-devel taglib taglib-devel lame lame-devel libvorbis libvorbis-devel libtheora libtheora-devel pcre.x86_64 ocaml-camlp4 ocaml-camlp4-devel.x86_64 pcre pcre-devel gcc-c++ libX11 libX11-devel flac vorbis-tools vorbinsgain.x86_64 mp3gain.x86_64
    
    wget -O /tmp/pcre-ocaml-6.2.5.tar.gz http://bitbucket.org/mmottl/pcre-ocaml/downloads/pcre-ocaml-6.2.5.tar.gz
    cd /tmp
    tar xzf pcre-ocaml-6.2.5.tar.gz
    cd pcre-ocaml-6.2.5
    sudo -u pypo make
    make install || true

    wget -O /tmp/liquidsoap-1.0.1-full.tar.bz2 http://sourceforge.net/projects/savonet/files/liquidsoap/1.0.1/liquidsoap-1.0.1-full.tar.bz2
    cd /tmp
    tar xjf liquidsoap-1.0.1-full.tar.bz2
    chown -R pypo:pypo /tmp/liquidsoap-1.0.1-full
    cd /tmp/liquidsoap-1.0.1-full

    cp PACKAGES.minimal PACKAGES
    sed -i 's/ocaml-flac/#ocaml-flac/g' PACKAGES

    sudo -u pypo ./configure --disable-camomile
    sudo -u pypo ./bootstrap
    sudo -u pypo make
    make install || true

    echo "Installing icecast2"
    yum -y install libxslt-devel.x86_64
    wget -O /tmp/icecast-2.3.3.tar.gz http://downloads.xiph.org/releases/icecast/icecast-2.3.3.tar.gz
    cd /tmp
    tar xzf icecast-2.3.3.tar.gz
    chown -R pypo:pypo /tmp/icecast-2.3.3
    cd /tmp/icecast-2.3.3
    sudo -u pypo ./configure
    sudo -u pypo make
    make install || true


    echo "* Setting up init.d scripts"
    #httpd

    #postgresql

    #media-monitor

    #pypo

    #monit
    #chkconfig --levels 235 monit on

    #rabbitmq: 
    #chkconfig rabbitmq-server on

    #icecast2
    
    
    echo "* Installing Airtime utils"



    echo "* Successful install of Airtime on CentOS!"
}

if [[ "$1" == "install" ]]; then
    install
elif [[ "$1" == "uninstall" ]]; then
    uninstall
else
    echo "install/uninstall parameter required"
fi
