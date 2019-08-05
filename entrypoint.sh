#!/bin/sh

#Based in work from Khanh Ngo "k@ndk.name" (https://github.com/ngoduykhanh/PowerDNS-Admin/blob/master/docker/PowerDNS-Admin/Dockerfile)

DB_MIGRATION_DIR='/opt/pdnsadmin/migrations'

if [ -z ${PDNS_PROTO} ];
 then PDNS_PROTO="http"
fi

if [ -z ${PDNS_PORT} ];
 then PDNS_PORT=8081
fi

if [ -z ${PDNS_HOST} ];
 then PDNS_HOST="127.0.0.1"
fi

if [ -z ${$PDNSADMIN_SQLA_DB_PORT} ];
 then $PDNSADMIN_SQLA_DB_PORT=3306
fi

# Wait for us to be able to connect to MySQL before proceeding
echo "===> Waiting for $PDNSADMIN_SQLA_DB_HOST MySQL service"
until nc -zv $PDNSADMIN_SQLA_DB_HOST $PDNSADMIN_SQLA_DB_PORT;
do
  echo "MySQL ($PDNSADMIN_SQLA_DB_HOST) is unavailable - sleeping"
  sleep 5
done

cat >/opt/pdnsadmin/config.py <<EOF
import os
basedir = os.path.abspath(os.path.dirname(__file__))
BIND_ADDRESS = '0.0.0.0'
TIMEOUT = 10
LOG_LEVEL = 'ALERT'
LOG_FILE = 'logfile.log'
SALT = '$2b$12$yLUMTIfl21FKJQpTkRQXCu'
UPLOAD_DIR = os.path.join(basedir, 'upload')
SAML_ENABLED = False
SAML_DEBUG = False
SAML_PATH = os.path.join(os.path.dirname(__file__), 'saml')
SAML_METADATA_URL = 'https://<hostname>/FederationMetadata/2007-06/FederationMetadata.xml'
SAML_METADATA_CACHE_LIFETIME = 1
SAML_ATTRIBUTE_ACCOUNT = 'https://example.edu/pdns-account'
SAML_SP_ENTITY_ID = 'http://<SAML SP Entity ID>'
SAML_SP_CONTACT_NAME = '<contact name>'
SAML_SP_CONTACT_MAIL = '<contact mail>'
SAML_SIGN_REQUEST = False
SAML_LOGOUT = False
EOF

if [ -z $PDNSADMIN_SECRET_KEY ];then echo "SECRET_KEY = 'We are the world'";else echo "SECRET_KEY = '$PDNSADMIN_SECRET_KEY'";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_PORT ];then echo "PORT = 9191";else echo "PORT = $PDNSADMIN_PORT";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_SQLA_DB_USER ];then echo "SQLA_DB_USER = 'pda'";else echo "SQLA_DB_USER = '$PDNSADMIN_SQLA_DB_USER'";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_SQLA_DB_PASSWORD ];then echo "SQLA_DB_PASSWORD = 'changeme'";else echo "SQLA_DB_PASSWORD = '$PDNSADMIN_SQLA_DB_PASSWORD'";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_SQLA_DB_HOST ];then echo "SQLA_DB_HOST = '127.0.0.1'";else echo "SQLA_DB_HOST = '$PDNSADMIN_SQLA_DB_HOST'";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_SQLA_DB_PORT ];then echo "SQLA_DB_PORT = 3306";else echo "SQLA_DB_PORT = $PDNSADMIN_SQLA_DB_PORT";fi >>/opt/pdnsadmin/config.py
if [ -z $PDNSADMIN_SQLA_DB_NAME ];then echo "SQLA_DB_NAME = 'pda'";else echo "SQLA_DB_NAME = '$PDNSADMIN_SQLA_DB_NAME'";fi >>/opt/pdnsadmin/config.py

cat >>/opt/pdnsadmin/config.py <<EOF
SQLALCHEMY_TRACK_MODIFICATIONS = True
SQLALCHEMY_DATABASE_URI = 'mysql://'+SQLA_DB_USER+':'+SQLA_DB_PASSWORD+'@'+SQLA_DB_HOST+':'+str(SQLA_DB_PORT)+'/'+SQLA_DB_NAME
EOF

cd /opt/pdnsadmin
virtualenv flask
source ./flask/bin/activate

echo "===> DB management"
if [ ! -d "${DB_MIGRATION_DIR}" ]; then
  echo "---> Running DB Init"
  flask db init --directory ${DB_MIGRATION_DIR}
  flask db migrate -m "Init DB" --directory ${DB_MIGRATION_DIR}
  flask db upgrade --directory ${DB_MIGRATION_DIR}
#  ./init_data.py
else
  echo "---> Running DB Migration"
  flask db migrate -m "Upgrade DB Schema" --directory ${DB_MIGRATION_DIR}
  flask db upgrade --directory ${DB_MIGRATION_DIR}
fi

echo "===> Update PDNS API connection info"
# initial setting if not available in the DB
mysql -h${PDNSADMIN_SQLA_DB_HOST} -u${PDNSADMIN_SQLA_DB_USER} -p${PDNSADMIN_SQLA_DB_PASSWORD} -P${PDNSADMIN_SQLA_DB_PORT} ${PDNSADMIN_SQLA_DB_NAME} -e "INSERT INTO setting (name, value) SELECT * FROM (SELECT 'pdns_api_url',
 '${PDNS_PROTO}://${PDNS_HOST}:${PDNS_PORT}') AS tmp WHERE NOT EXISTS (SELECT name FROM setting WHERE name = 'pdns_api_url') LIMIT 1;"
mysql -h${PDNSADMIN_SQLA_DB_HOST} -u${PDNSADMIN_SQLA_DB_USER} -p${PDNSADMIN_SQLA_DB_PASSWORD} -P${PDNSADMIN_SQLA_DB_PORT} ${PDNSADMIN_SQLA_DB_NAME} -e "INSERT INTO setting (name, value) SELECT * FROM (SELECT 'pdns_api_key',
 '${PDNS_API_KEY}') AS tmp WHERE NOT EXISTS (SELECT name FROM setting WHERE name = 'pdns_api_key') LIMIT 1;"
/usr/bin/gunicorn -t 120 --workers 4 --bind '0.0.0.0:$PDNSADMIN_PORT' --log-level info app:app
