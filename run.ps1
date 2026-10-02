# Bootstrap for the short launch line (PowerShell as Administrator):
#   irm https://raw.githubusercontent.com/iMironRU/IPBanManager/main/run.ps1 | iex
# Kept ASCII-only and without BOM so that iex can parse it. IPBan-Manager.ps1 itself
# has a UTF-8 BOM (needed for Cyrillic in Windows PowerShell 5.1), which iex cannot parse.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/iMironRU/IPBanManager/main/IPBan-Manager.ps1').TrimStart([char]0xFEFF)))
