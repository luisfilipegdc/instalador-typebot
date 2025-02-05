#!/bin/bash

# Coleta informações do usuário
read -p "Digite o domínio para o Typebot (ex: typebot.exemplo.com): " TYPEBOT_DOMAIN
read -p "Digite a porta para o Typebot (ex: 3001): " TYPEBOT_PORT
read -p "Digite o domínio para o Chat (ex: chat.exemplo.com): " CHAT_DOMAIN
read -p "Digite a porta para o Chat (ex: 3002): " CHAT_PORT
read -p "Digite o domínio para o Storage (ex: storage.exemplo.com): " STORAGE_DOMAIN
read -p "Digite a porta para o Minio (ex: 9000): " MINIO_PORT
read -p "Digite o email do administrador: " ADMIN_EMAIL
read -p "Digite a senha do banco de dados PostgreSQL para o Typebot: " POSTGRES_PASSWORD
read -p "Digite o host do servidor SMTP (ex: smtp.zoho.com): " SMTP_HOST
read -p "Digite a porta do servidor SMTP (ex: 465 ou 587): " SMTP_PORT
read -p "Digite o nome de usuário do SMTP: " SMTP_USERNAME
read -p "Digite a senha do SMTP: " SMTP_PASSWORD

# Define SMTP_SECURE baseado na porta
if [[ "$SMTP_PORT" == "465" ]]; then
  SMTP_SECURE="true"
  SMTP_AUTH_DISABLED="false"
elif [[ "$SMTP_PORT" == "587" ]]; then
  SMTP_SECURE="false"
  SMTP_AUTH_DISABLED="false"
else
  echo "Porta SMTP inválida. Use 465 ou 587."
  exit 1
fi

# Gera a chave secreta de criptografia
ENCRYPTION_SECRET=$(openssl rand -base64 24)

# Salva a chave em um arquivo
echo "$ENCRYPTION_SECRET" > encryption_secret.txt

# Exibe a mensagem para o usuário
echo "A chave secreta de criptografia foi salva no arquivo encryption_secret.txt"

# Atualiza o docker-compose.yml
cat <<EOF > docker-compose.yml
version: '3.3'
services:
  typebot-db:
    image: postgres:13
    restart: always
    volumes:
      - db_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=typebot
      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD
  typebot-builder:
    ports:
      - $TYPEBOT_PORT:3000
    image: baptistearno/typebot-builder:latest
    restart: always
    depends_on:
      - typebot-db
    environment:
      - DATABASE_URL=postgresql://postgres:$POSTGRES_PASSWORD@typebot-db:5432/typebot
      - NEXTAUTH_URL=https://$TYPEBOT_DOMAIN
      - NEXT_PUBLIC_VIEWER_URL=https://$CHAT_DOMAIN
      - NEXTAUTH_URL_INTERNAL=http://localhost:$TYPEBOT_PORT
      - ENCRYPTION_SECRET=$ENCRYPTION_SECRET
      - ADMIN_EMAIL=$ADMIN_EMAIL
      - DISABLE_SIGNUP=false
      - SMTP_HOST=$SMTP_HOST
      - SMTP_PORT=$SMTP_PORT
      - SMTP_SECURE=$SMTP_SECURE
      - SMTP_USERNAME=$SMTP_USERNAME
      - SMTP_PASSWORD=$SMTP_PASSWORD
      - SMTP_AUTH_DISABLED=$SMTP_AUTH_DISABLED
      - NEXT_PUBLIC_SMTP_FROM='Suporte Typebot' <$ADMIN_EMAIL>
      - S3_ACCESS_KEY=minio
      - S3_SECRET_KEY=minio123
      - S3_BUCKET=typebot
      - S3_ENDPOINT=$STORAGE_DOMAIN
  typebot-viewer:
    ports:
      - $CHAT_PORT:3000
    image: baptistearno/typebot-viewer:latest
    restart: always
    environment:
      - DATABASE_URL=postgresql://postgres:$POSTGRES_PASSWORD@typebot-db:5432/typebot
      - NEXTAUTH_URL=https://$TYPEBOT_DOMAIN
      - NEXT_PUBLIC_VIEWER_URL=https://$CHAT_DOMAIN
      - NEXTAUTH_URL_INTERNAL=http://localhost:$TYPEBOT_PORT
      - ENCRYPTION_SECRET=$ENCRYPTION_SECRET
      - S3_ACCESS_KEY=minio
      - S3_SECRET_KEY=minio123
      - S3_BUCKET=typebot
      - S3_ENDPOINT=$STORAGE_DOMAIN
  mail:
    image: bytemark/smtp
    restart: always
  minio:
    labels:
      virtual.host: '$STORAGE_DOMAIN'
      virtual.port: '$MINIO_PORT'
      virtual.tls-email: '$ADMIN_EMAIL'
    image: minio/minio
    command: server /data
    ports:
      - '$MINIO_PORT:9000'
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: minio123
    volumes:
      - s3_data:/data
  createbuckets:
    image: minio/mc
    depends_on:
      - minio
    entrypoint: >
      /bin/sh -c "
      sleep 10;
      /usr/bin/mc config host add minio http://minio:$MINIO_PORT minio minio123;
      /usr/bin/mc mb minio/typebot;
      /usr/bin/mc anonymous set public minio/typebot/public;
      exit 0;
      "
volumes:
  db_data:
  s3_data:
EOF

# Instala as dependências e inicia os containers
apt update && apt install certbot python3-certbot-nginx docker-compose python2-minimal mc -y
usermod -aG docker $USER
docker-compose up -d

# Configuração Nginx para Typebot
nano /etc/nginx/sites-available/typebot <<EOF1
server {
  listen 80;
  server_name $TYPEBOT_DOMAIN;

  location / {
    proxy_pass http://127.0.0.1:$TYPEBOT_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF1

# Configuração Nginx para Chat
nano /etc/nginx/sites-available/chat <<EOF2
server {
  listen 80;
  server_name $CHAT_DOMAIN;

  location / {
    proxy_pass http://127.0.0.1:$CHAT_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF2

ln -s /etc/nginx/sites-available/typebot /etc/nginx/sites-enabled/
ln -s /etc/nginx/sites-available/chat /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx
certbot --nginx -d $TYPEBOT_DOMAIN && certbot --nginx -d $CHAT_DOMAIN
nginx -t && systemctl restart nginx

echo "Instalação concluída!"