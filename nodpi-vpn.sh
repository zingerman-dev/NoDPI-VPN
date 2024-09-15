#!/bin/bash

# Переменные
SHADOWSOCKS_PASSWORD=$(cat password.txt)
SHADOWSOCKS_PORT=8388
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
DOMAINS_FILE="domains.txt"
CERT_EMAIL=$(cat email.txt)

# Проверка установки программы
check_installation() {
    local program=$1
    if ! command -v $program &>/dev/null; then
        echo "$program не установлен. Устанавливаю..."
        return 1
    else
        echo "$program уже установлен."
        return 0
    fi
}

# Шаг 1: Установка необходимых программ
install_dependencies() {
    echo "Проверка и установка зависимостей..."
    for program in "shadowsocks-libev" "simple-obfs" "ufw" "nginx" "certbot" "nano"; do
        if ! check_installation $program; then
            sudo apt update
            sudo apt install -y $program
            if [ $? -ne 0 ]; then
                echo "Ошибка при установке $program. Скрипт завершен."
                exit 1
            fi
        fi
    done
}

# Проверка, активен ли UFW
is_ufw_active() {
    sudo ufw status | grep -qw "Status: active"
}

# Проверка, открыт ли порт
is_port_open() {
    local port=$1
    sudo ufw status | grep -qw "$port"
}

# Открытие нового порта, если он еще не открыт
open_new_port() {
    local new_port=$1

    # Проверяем, открыт ли уже порт
    if is_port_open $new_port; then
        echo "Порт $new_port уже открыт."
    else
        echo "Открываю порт $new_port..."
        sudo ufw allow $new_port/tcp
        sudo ufw allow $new_port/udp
    fi
}

# Шаг 2: Конфигурация Shadowsocks
configure_shadowsocks() {
    echo "Конфигурирую Shadowsocks..."
    sudo tee /etc/shadowsocks-libev/config.json >/dev/null <<EOL
{
    "server": "0.0.0.0",
    "server_port": $SHADOWSOCKS_PORT,
    "password": "$SHADOWSOCKS_PASSWORD",
    "method": "aes-256-gcm",
    "plugin": "obfs-server",
    "plugin_opts": "obfs=tls;obfs-host=www.google.com"
}
EOL

    sudo chmod 600 /etc/shadowsocks-libev/config.json
    if [ $? -ne 0 ]; then
        echo "Ошибка при настройке Shadowsocks. Скрипт завершен."
        exit 1
    fi
}

# Шаг 3: Открытие порта в ufw (добавление порта без закрытия других)
open_port() {
    echo "Проверяю и открываю порт $SHADOWSOCKS_PORT..."
    open_new_port $SHADOWSOCKS_PORT  # Добавление нового порта

    # Проверяем, активен ли UFW, если нет - активируем
    if is_ufw_active; then
        echo "UFW уже активен."
    else
        echo "UFW не активен, активирую..."
        sudo ufw --force enable  # Активируем UFW, если он не активен
    fi

    if [ $? -ne 0 ]; then
        echo "Ошибка при настройке UFW. Скрипт завершен."
        exit 1
    fi
}

# Проверка, является ли строка IP-адресом
is_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Шаг 4: Настройка доменов для Nginx (HTTP)
configure_nginx_http() {
    while IFS= read -r SUBDOMAIN; do
        if is_ip "$SUBDOMAIN"; then
            echo "Настраиваю Nginx для IP-адреса $SUBDOMAIN (только HTTP)..."

            # Создание конфигурации HTTP для IP
            sudo tee $NGINX_CONF_DIR/$SUBDOMAIN >/dev/null <<EOL
server {
    listen 80;
    server_name $SUBDOMAIN;

    location / {
        proxy_pass http://localhost:$SHADOWSOCKS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

        else
            echo "Настраиваю Nginx для домена $SUBDOMAIN..."

            # Создание конфигурации HTTP для домена
            sudo tee $NGINX_CONF_DIR/$SUBDOMAIN >/dev/null <<EOL
server {
    listen 80;
    server_name $SUBDOMAIN;

    location / {
        proxy_pass http://localhost:$SHADOWSOCKS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

        fi

        # Удаление существующих симлинков перед созданием новых
        sudo rm -f $NGINX_ENABLED_DIR/$SUBDOMAIN
        sudo ln -s $NGINX_CONF_DIR/$SUBDOMAIN $NGINX_ENABLED_DIR/
        if [ $? -ne 0 ]; then
            echo "Ошибка при настройке Nginx для $SUBDOMAIN. Скрипт завершен."
            exit 1
        fi
    done <"$DOMAINS_FILE"
}

# Шаг 5: Выпуск сертификатов SSL с помощью Certbot
issue_certificates() {
    echo "Запрашиваю сертификаты для всех доменов..."
    while IFS= read -r SUBDOMAIN; do
        if ! is_ip "$SUBDOMAIN"; then
            sudo certbot --nginx -d $SUBDOMAIN --non-interactive --agree-tos --email $CERT_EMAIL
            if [ $? -ne 0 ]; then
                echo "Ошибка при получении сертификатов для $SUBDOMAIN."
                exit 1
            fi
        else
            echo "Пропуск SSL для IP-адреса $SUBDOMAIN."
        fi
    done <"$DOMAINS_FILE"
}

# Шаг 6: Обновление конфигурации Nginx для SSL
update_nginx_for_ssl() {
    while IFS= read -r SUBDOMAIN; do
        echo "Обновляю конфигурацию для SSL для домена $SUBDOMAIN..."

        sudo tee $NGINX_CONF_DIR/$SUBDOMAIN >/dev/null <<EOL
server {
    listen 80;
    server_name $SUBDOMAIN;

    # Перенаправление на HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $SUBDOMAIN;

    ssl_certificate /etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUBDOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://localhost:$SHADOWSOCKS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

        sudo rm -f $NGINX_ENABLED_DIR/$SUBDOMAIN
        sudo ln -s $NGINX_CONF_DIR/$SUBDOMAIN $NGINX_ENABLED_DIR/
        if [ $? -ne 0 ]; then
            echo "Ошибка при обновлении Nginx для $SUBDOMAIN. Скрипт завершен."
            exit 1
        fi
    done <"$DOMAINS_FILE"
}

# Шаг 7: Перезагрузка Nginx
reload_nginx() {
    echo "Перезагружаю Nginx..."
    sudo systemctl reload nginx
    if [ $? -ne 0 ]; then
        echo "Ошибка при перезагрузке Nginx. Скрипт завершен."
        exit 1
    fi
}

# Шаг 8: Запуск Shadowsocks
start_shadowsocks() {
    echo "Запускаю Shadowsocks..."
    sudo systemctl start shadowsocks-libev
    sudo systemctl enable shadowsocks-libev
    if [ $? -ne 0 ]; then
        echo "Ошибка при запуске Shadowsocks. Скрипт завершен."
        exit 1
    fi
}

# Основная логика
echo "Начинаю настройку..."

install_dependencies
configure_shadowsocks
open_port
configure_nginx_http
reload_nginx  # Перезагрузка Nginx для активации HTTP конфигураций
issue_certificates
update_nginx_for_ssl
reload_nginx  # Перезагрузка Nginx для активации HTTPS
start_shadowsocks

echo "Все задачи успешно выполнены!"
