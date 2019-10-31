  
#!/bin/bash

sudo -i <<'EOF'
echo "export DSS_USER=<DSS_USER>" > /tmp/variable.sh
echo "export DSS_VERSION=<DSS_VERSION>" >> /tmp/variable.sh
echo "export YOUR_DSS_USER=<YOUR_DSS_USER>" >> /tmp/variable.sh
echo "export YOUR_USER_PASSWORD=<YOUR_USER_PASSWORD>" >> /tmp/variable.sh
echo "export DSS_DEPLOYER_URL=<DSS_DEPLOYER_URL>" >> /tmp/variable.sh
echo "export DSS_MONITOR_URL=<DSS_MONITOR>URL>" >> /tmp/variable.sh
chmod 777 /tmp/variable.sh
EOF



echo -----------------------------
echo Reset design variables
echo -----------------------------

sudo -i <<'EOF'
source /tmp/variable.sh
rm -f /tmp/variable.sh
echo "export DSS_USER=$DSS_USER" > /tmp/variable.sh
echo "export DSS_VERSION=$DSS_VERSION" >> /tmp/variable.sh
echo "export YOUR_DSS_USER=$YOUR_DSS_USER" > /tmp/variable.sh
echo "export YOUR_USER_PASSWORD=$YOUR_USER_PASSWORD" > /tmp/variable.sh
echo "export DSS_DEPLOYER_URL=$DSS_DEPLOYER_URL" >> /tmp/variable.sh
echo "export DSS_MONITOR_URL=$DSS_MONITOR_URL" >> /tmp/variable.sh
chmod 777 /tmp/variable.sh
EOF

cat /tmp/variable.sh

echo -----------------------------
echo Install api deployer + api node
echo -----------------------------

source /tmp/variable.sh

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
./dataiku-dss-$DSS_VERSION/installer.sh -t api -d /data/dataiku/api_dir -p 13000 -l /data/$DSS_USER/license.json
./dataiku-dss-$DSS_VERSION/installer.sh -t apideployer -d /data/dataiku/deployer_dir -p 14000 -l /data/$DSS_USER/license.json
EOF

source /tmp/variable.sh
sudo -i "/data/dataiku/dataiku-dss-$DSS_VERSION/scripts/install/install-boot.sh" "/data/dataiku/api_dir" $DSS_USER
sudo -i "/data/dataiku/dataiku-dss-$DSS_VERSION/scripts/install/install-boot.sh" "/data/dataiku/deployer_dir" $DSS_USER
sudo yum install -y jq


echo -----------------------------
echo Start api node + api deployer
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
cd /data/dataiku
./api_dir/bin/dss start 
./deployer_dir/bin/dss start 
EOF

echo "sleeping 10s to allow DSS to start"
sleep 10
echo "awake!"

echo -----------------------------
echo Generate API Key -- api deployer
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
AUTO_JSON=$(./deployer_dir/bin/dsscli api-key-create --output json --admin true --description "admin key for deployer node setup script" --label "auto_script_key")
echo "export DEPLOYER_KEY=$(echo $AUTO_JSON | jq '.[] | .key')" >> /tmp/variable.sh
source /tmp/variable.sh
echo "DEPLOYER_KEY: " $DEPLOYER_KEY
EOF

source /tmp/variable.sh


echo -----------------------------
echo Create User and Group -- api deployer
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
./deployer_dir/bin/dsscli group-create --description "Data Scientists from Business X" --source-type LOCAL --may-create-project true --may-write-unsafe-code true --may-write-safe-code true --may-create-code-envs true --may-develop-plugins true --may-create-published-api-services true biz_x_data_scientists
./deployer_dir/bin/dsscli user-create --source-type LOCAL --display-name $YOUR_DSS_USER --user-profile DESIGNER --group biz_x_data_scientists $YOUR_DSS_USER $YOUR_USER_PASSWORD
echo "Finished with User and Group Creation!"
EOF



echo -----------------------------
echo Get API Node API Key -- api node
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku/api_dir
API_JSON=$(./bin/apinode-admin admin-key-create --output json  --description "admin key for deployer node setup script" --label "auto_script_key")
echo "export API_NODE_KEY=$(echo $API_JSON | jq .key)" >> /tmp/variable.sh
source /tmp/variable.sh
echo "API_NODE_KEY: " $API_NODE_KEY
EOF


echo -----------------------------
echo Set-up for dkumonitor -- dkm
echo -----------------------------

sudo -i <<'EOF'
source /tmp/variable.sh
sudo yum install -y jq
export latest_version=$(curl -s https://downloads.dataiku.com/latest_dkumonitor.json|jq -r '.version')
curl -O https://downloads.dataiku.com/public/dkumonitor/$latest_version/dkumonitor-$latest_version.tar.gz
curl -O https://downloads.dataiku.com/public/dkumonitor/$latest_version/dkumonitor-$latest_version.tar.gz
sudo mv dkumonitor-$latest_version.tar.gz /data/dataiku/
sudo tar -xzvf /data/dataiku/dkumonitor-$latest_version.tar.gz  -C /data/dataiku/
sudo chown $DSS_USER:$DSS_USER -R /data/dataiku/dkumonitor-$latest_version/
EOF

echo -----------------------------
echo  Install dkumonitor -- dkm
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
cd /data/dataiku
mkdir dkm_dir
./dkumonitor-0.0.5/installer -d /data/dataiku/dkm_dir/ -p 15000
EOF

echo -----------------------------
echo  Run dkumonitor integration -- dkm
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
/data/dataiku/data_dir/bin/dss stop
/data/dataiku/data_dir/bin/dssadmin install-monitoring-integration -graphiteServer localhost:15001
/data/dataiku/data_dir/bin/dss start
/data/dataiku/dkm_dir/bin/dkm start
EOF

echo -----------------------------
echo  Add Nginx Entries 
echo -----------------------------

sudo -i <<'EOF'
source /tmp/variable.sh

echo '
import os

server_name = os.environ["DSS_DEPLOYER_URL"]

server_conf_deployer = """
    server { 
        listen 80; 
        server_name %s; 
        location / { 
            proxy_pass http://localhost:14000/; 
            proxy_redirect off; 
            proxy_read_timeout 3600; 
            proxy_send_timeout 600; 
            client_max_body_size 0; 
            proxy_http_version 1.1;
            proxy_set_header Host $http_host; 
            proxy_set_header Upgrade $http_upgrade; 
            proxy_set_header Connection "upgrade"; 
            } 
        }
""" %server_name

with open("/etc/nginx/nginx.conf", "r") as f: 
    contents = f.readlines()
f.close()

contents.insert(len(contents)-2, server_conf_deployer)
contents = "".join(contents)

with open("/etc/nginx/nginx.conf", "w") as f: 
    f.write(contents)
f.close 

server_name = os.environ["DSS_MONITOR_URL"]

server_conf_monitoring = """
    server { 
        listen 80; 
        server_name %s; 
        location / { 
            proxy_pass http://localhost:15000/; 
            proxy_redirect off; 
            proxy_read_timeout 3600; 
            proxy_send_timeout 600; 
            client_max_body_size 0; 
            proxy_http_version 1.1;
            proxy_set_header Host $http_host; 
            proxy_set_header Upgrade $http_upgrade; 
            proxy_set_header Connection "upgrade"; 
            } 
        }
""" %server_name

with open("/etc/nginx/nginx.conf", "r") as f: 
    contents = f.readlines()
f.close()

contents.insert(len(contents)-2, server_conf_monitoring)
contents = "".join(contents)

with open("/etc/nginx/nginx.conf", "w") as f: 
    f.write(contents)
f.close 
' > /tmp/modify_nginx.py

python /tmp/modify_nginx.py

cat /etc/nginx/nginx.conf 

systemctl restart nginx
EOF

sudo -i <<'EOF'
source /tmp/variable.sh
echo "API_NODE_KEY: " $API_NODE_KEY
EOF
