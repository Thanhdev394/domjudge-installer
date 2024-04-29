#!/usr/bin/env bash

#
# This is a script that can automatically
# setup DOMjudge server & judgehost, inside a same server.
#

# you can leave it by its default value
USERNAME=domjudge
USER_PASSWORD=domjudge
MYSQL_PWD=FQoiwjjfQIfijf214
PHPMYADMIN_PWD=root
RELEASE=domjudge-8.2.2

echo ""
echo '####################'
echo '  Upgrading System  '
echo '####################'
echo ""

sudo apt -y update
# sudo apt -y upgrade

echo ""
echo '##########################'
echo '  Installing dependencies '
echo '##########################'
echo ""

sudo apt -y install gcc g++ make zip unzip \
    apache2 php php-cli libapache2-mod-php \
    php-gd php-curl php-mysql php-json php-zip \
    php-gmp php-xml php-mbstring \
    bsdmainutils ntp libcgroup-dev \
    linuxdoc-tools linuxdoc-tools-text \
    groff texlive-latex-recommended texlive-latex-extra \
    texlive-fonts-recommended texlive-lang-european curl git

sudo apt -y install libcurl4-gnutls-dev libjsoncpp-dev libmagic-dev

echo ""
echo '###################################'
echo '  Installing appropriate compilers '
echo '###################################'
echo ""

sudo apt -y install make sudo debootstrap libcgroup-dev \
    php-cli php-curl php-json php-zip procps \
    gcc g++ openjdk-8-jre-headless \
    openjdk-8-jdk ghc fp-compiler

echo ""
echo '#####################'
echo '  Installing  MySQL  '
echo '#####################'
echo ""

echo "mysql-server mysql-server/root_password password $MYSQL_PWD" | sudo debconf-set-selections
echo "mysql-server mysql-server/root_password_again password $MYSQL_PWD" | sudo debconf-set-selections
sudo apt -y install mysql-server expect

# automate mysql_secure_installation
SECURE_MYSQL=$(expect -c "
set timeout 3
spawn mysql_secure_installation
expect \"Enter password for user root:\"
send \"$MYSQL_PWD\r\"
expect \"Press y|Y for Yes, any other key for No\"
send \"n\r\"
expect \"Change the password for root?\"
send \"n\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")
echo "$SECURE_MYSQL"

sudo systemctl start mysql
mysql -u root -p$MYSQL_PWD -D mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY 'root';flush privileges;"

echo ""
echo '#########################'
echo '  Installing phpmyadmin  '
echo '#########################'
echo ""

echo phpmyadmin phpmyadmin/dbconfig-install boolean true | sudo debconf-set-selections
echo phpmyadmin phpmyadmin/app-password-confirm password $PHPMYADMIN_PWD | sudo debconf-set-selections
echo phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_PWD | sudo debconf-set-selections
echo phpmyadmin phpmyadmin/mysql/app-pass password $MYSQL_PWD | sudo debconf-set-selections
echo phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2 | sudo debconf-set-selections
sudo apt -y install phpmyadmin --no-install-recommends

echo ""
echo '##################################'
echo '  Downloading DOMJudge and setup  '
echo '##################################'
echo ""

# go to $USERNAME dir
cd /home/$USERNAME
mkdir domjudge

# download and rename folder
wget https://www.domjudge.org/releases/$RELEASE.tar.gz
tar xzf $RELEASE.tar.gz
mv $RELEASE domjudge-files
rm -rf $RELEASE.tar.gz

# configuring domjudge
mkdir /home/$USERNAME/domjudge
cd /home/$USERNAME/domjudge-files
./configure --prefix=/home/$USERNAME/domjudge

# compiling domjudge
make domserver && sudo make install-domserver
make judgehost && sudo make install-judgehost
make docs && sudo make install-docs

echo ""
echo '########################'
echo '  Database installation '
echo '########################'
echo ""

cd /home/$USERNAME/domjudge/domserver/bin
./dj_setup_database genpass
./dj_setup_database -u root -p $MYSQL_PWD install

echo ""
echo '###########################'
echo '  Web server configuration '
echo '###########################'
echo ""

sudo rm -rf /etc/apache2/conf-available/domjudge.conf
sudo ln -s /home/$USERNAME/domjudge/domserver/etc/apache.conf /etc/apache2/conf-available/domjudge.conf
sudo a2enmod rewrite
sudo a2enconf domjudge
sudo systemctl stop apache2 && sudo systemctl start apache2

echo ""
echo '#########################'
echo '  Installing judgehost   '
echo '#########################'
echo ""

sudo useradd -d /nonexistent -U -M -s /bin/false domjudge-run
sudo groupadd domjudge-run
sudo chmod +rx /home/$USERNAME
sudo ln -s /home/$USERNAME/domjudge/judgehost/etc/sudoers-domjudge /etc/sudoers.d/sudoers-domjudge
sudo sed -i "s/console=tty1 console=ttyS0/console=tty1 console=ttyS0 cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0/g" /etc/default/grub
sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty1 console=ttyS0/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty1 console=ttyS0 cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0/g" /etc/default/grub.d/50-cloudimg-settings.cfg
sudo update-grub
sudo /home/$USERNAME/domjudge/judgehost/bin/dj_make_chroot


JUDGEHOST=$(cat <<_EOF_
[Unit]
Description=DOMjudge's judgehost service
After=mysql.service
[Service]
ExecStart=DOMJUDGE_USER_PATH/domjudge/judgehost/bin/judgedaemon
Restart=on-failure
User=$USERNAME
KillSignal=SIGINT
SendSIGKILL=no
Type=forking

[Install]
WantedBy=default.target
_EOF_
)

JUDGEHOST_CGROUPS=$(cat <<_EOF_
[Unit]
Description=DOMjudge's judgehost cgroup creation service
After=mysql.service

[Service]
ExecStart=DOMJUDGE_USER_PATH/domjudge/judgehost/bin/create_cgroups
Restart=no
Type=oneshot

[Install]
WantedBy=default.target
_EOF_
)


# replace constant with its appropriate value
JUDGEHOST=$(echo "$JUDGEHOST" | sed "s/DOMJUDGE_USER_PATH/\/home\/$USERNAME/g")
JUDGEHOST_CGROUPS=$(echo "$JUDGEHOST_CGROUPS" | sed "s/DOMJUDGE_USER_PATH/\/home\/$USERNAME/g")

echo "$JUDGEHOST" | sudo tee -a /etc/systemd/system/judgehost.service
echo "$JUDGEHOST_CGROUPS" | sudo tee -a /etc/systemd/system/judgehost_cgroups.service

sudo systemctl enable judgehost
sudo systemctl enable judgehost_cgroups

exit 1

