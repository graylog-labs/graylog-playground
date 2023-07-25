#Cleanup and get docker installed
sudo apt-get remove -y docker docker-engine docker.io containerd runc 
apt-get install -y ca-certificates curl gnupg lsb-release wget
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
echo -e "\n\ndeb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin openjdk-11-jre-headless jq

#system Changes
sudo sysctl -w vm.max_map_count=262144

#Mongo
docker compose -f docker-compose-glcluster.yml pull
docker compose -f docker-compose-glcluster.yml create
sudo docker compose -f docker-compose-glcluster.yml start mongo.one.db
sudo docker compose -f docker-compose-glcluster.yml start mongo.two.db
sudo docker compose -f docker-compose-glcluster.yml start mongo.three.db
docker exec -it mongo.one.db mongosh --eval "rs.initiate({_id:'rs0', members: [{_id:0, host: 'mongo.one.db'},{_id:1, host: 'mongo.two.db'},{_id:2, host: 'mongo.three.db'}]})"

#OpenSearch and Graylog
sudo docker compose -f docker-compose-glcluster.yml up -d

