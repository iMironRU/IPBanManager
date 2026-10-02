# IPBanManager

Менеджер [IPBan](https://github.com/DigitalRuby/IPBan) (DigitalRuby) для Windows: установка, обновление, удаление, настройки (попытки, время бана, белый список с автоопределением частных сетей и RDP-подключений).

## Запуск одной строкой

PowerShell **от имени администратора**:

```powershell
[Net.ServicePointManager]::SecurityProtocol=3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/iMironRU/IPBanManager/main/IPBan-Manager.ps1).TrimStart([char]0xFEFF)))
```

Откроется интерактивное меню. Для неинтерактивного режима допишите в конец `-Action <действие>`:

```powershell
[Net.ServicePointManager]::SecurityProtocol=3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/iMironRU/IPBanManager/main/IPBan-Manager.ps1).TrimStart([char]0xFEFF))) -Action Status
```

| Действие    | Что делает |
|-------------|------------|
| `Install`   | установить и применить сохранённые настройки |
| `Update`    | обновить до последнего релиза, настройки сохраняются |
| `Uninstall` | удалить службу, правила брандмауэра, каталог |
| `Apply`     | применить сохранённые настройки к `ipban.config` и перезапустить службу |
| `Status`    | вывести состояние |

Зачем каждая часть строки:
- `SecurityProtocol=3072` — включает TLS 1.2, без него Windows PowerShell 5.1 на старых системах не скачает файл с GitHub;
- `[scriptblock]::Create(...)` вместо `iex` — позволяет передать `-Action`, а функции скрипта не засоряют текущую сессию;
- `.TrimStart([char]0xFEFF)` — убирает BOM: файл хранится в UTF-8 с BOM, иначе кириллица ломается при локальном запуске в PowerShell 5.1.

## Локальный запуск

```powershell
.\IPBan-Manager.ps1
.\IPBan-Manager.ps1 -Action Install
```

Настройки менеджера хранятся в `%ProgramData%\IPBanManager\settings.json` и переживают обновление IPBan.
