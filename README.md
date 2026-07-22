# VPN Setup: VLESS + REALITY (sing-box)

Быстрая настройка защищённого VPN на чистом VPS.

## Что делает скрипт

1. Обновляет систему (Ubuntu/Debian)
2. Устанавливает последнюю версию sing-box
3. Настраивает VLESS + REALITY (маскировка трафика под обычный HTTPS)
4. Оптимизирует сетевые параметры (BBR, fastopen)
5. Создаёт systemd-сервис с автообновлением
6. Генерирует клиентские конфиги для macOS и Android

## Использование

```bash
# SSH на VPS и запуск
ssh root@YOUR_IP
curl -sL https://raw.githubusercontent.com/.../setup.sh -o setup.sh
bash setup.sh --ip YOUR_IP

# Или с доменом (рекомендуется)
bash setup.sh --domain your-domain.com
```

## После запуска скрипт покажет

- IP и порт сервера
- UUID для подключения
- Reality Public Key
- Short ID
- VLESS URL для импорта в клиент

## Подключение клиентов

### macOS
1. Установить [Hiddify](https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532) или NekoRay
2. Нажать + → Вставить из буфера обмена (VLESS URL)
3. Подключиться

### Android / Samsung
1. Установить [Hiddify](https://play.google.com/store/apps/details?id=io.hiddify.android) или NekoBox
2. Нажать + → Вставить из буфера
3. VLESS URL автоматически распознается
4. Подключиться

## Файлы на сервере

| Файл | Описание |
|------|----------|
| `/etc/sing-box/config.json` | Конфигурация sing-box |
| `/usr/local/bin/sing-box-updater.sh` | Скрипт автообновления |
| `/root/vpn-clients/` | Клиентские конфиги |

## Управление

```bash
systemctl status sing-box      # Статус
systemctl restart sing-box     # Перезапуск
journalctl -u sing-box -f      # Логи
sing-box check -c /etc/sing-box/config.json  # Проверка конфига
```

## Добавление клиента

```bash
# Новый UUID
sing-box generate uuid

# Добавить в /etc/sing-box/config.json → inbounds[0].users
# Перезапустить
systemctl restart sing-box
```

## Автообновление

Проверка обновлений sing-box каждую неделю через systemd timer.

```bash
systemctl list-timers sing-box-update*  # Проверить расписание
```

## Требования

- Ubuntu 20.04/22.04/24.04 или Debian 11/12
- Минимум 512MB RAM
- Порт 443 (или другой) должен быть открыт
