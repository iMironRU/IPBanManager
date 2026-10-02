# IPBanManager

Менеджер [IPBan](https://github.com/DigitalRuby/IPBan) (DigitalRuby) для Windows: установка, обновление, удаление, настройки (попытки, время бана, белый список с автоопределением частных сетей и RDP-подключений).

## Запуск одной строкой

PowerShell **от имени администратора**:

```powershell
irm https://raw.githubusercontent.com/iMironRU/IPBanManager/main/IPBan-Manager.ps1 | iex
```

Откроется интерактивное меню. Без меню, сразу с действием:

```powershell
iex "& {$(irm https://raw.githubusercontent.com/iMironRU/IPBanManager/main/IPBan-Manager.ps1)} -Action Status"
```

| Действие    | Что делает |
|-------------|------------|
| `Install`   | установить и применить сохранённые настройки |
| `Update`    | обновить до последнего релиза, настройки сохраняются |
| `Uninstall` | удалить службу, правила брандмауэра, каталог |
| `Apply`     | применить сохранённые настройки к `ipban.config` и перезапустить службу |
| `Status`    | вывести состояние |

На Windows Server 2016 / 2012 R2, если `irm` пишет «Could not create SSL/TLS secure channel», допишите в начало строки `[Net.ServicePointManager]::SecurityProtocol=3072;`.

## Белый список

В ручной список можно добавлять:
- IP-адреса и подсети: `203.0.113.5`, `10.0.0.0/8`, `2001:db8::/32`;
- доменные имена: `home.example.ru` — удобно для динамического IP;
- URL текстового списка адресов (по одному на строку), например `https://uptimerobot.com/inc/files/ips/IPv4andIPv6.txt`.

Домены и URL записываются в `ipban.config` как есть, IPBan сам перечитывает их раз в 5 минут. Поэтому смена IP у домена подхватывается без участия менеджера, а старый адрес из белого списка уходит.

## Локальный запуск

Файл хранится в UTF-8 **без BOM** — иначе не сработал бы `irm | iex`. Поэтому Windows PowerShell 5.1 прочитает кириллицу неверно, если запустить файл как обычно. Запускайте так:

```powershell
iex (Get-Content .\IPBan-Manager.ps1 -Raw -Encoding UTF8)
```

В PowerShell 7 работает обычный `.\IPBan-Manager.ps1 -Action Install`.

Настройки менеджера хранятся в `%ProgramData%\IPBanManager\settings.json` и переживают обновление IPBan.
