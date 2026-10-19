# Локальная подпись Windows-выпусков

Этот способ предназначен только для закрытого тестирования. Самоподписанная
подпись подтверждает неизменность файла после выпуска, но не делает приложение
доверенным на чужом ПК и не устраняет предупреждение SmartScreen.

## Создание и резервирование

На Windows VM выполните:

```powershell
Set-Location C:\Users\Andrei\source\repos\SendFileOverWifi\Windows
.\CreateDevelopmentSigningCertificate.ps1
```

Скрипт интерактивно запросит пароль PFX и создаст:

- `Documents\SendFileOverWiFi Signing\SendFileOverWiFi-development.pfx` —
  зашифрованный закрытый ключ;
- `Documents\SendFileOverWiFi Signing\SendFileOverWiFi-development.cer` —
  открытый сертификат;
- запись сертификата в `Cert:\CurrentUser\My` Windows-пользователя.

Нужно сразу создать вторую локальную резервную копию PFX вне VM, например на
Mac в `~/Library/Application Support/SendFileOverWiFi/signing/`. PFX, его
пароль и thumbprint не добавляются в Git, облачные репозитории, артефакты
сборок или переписку.

Если VM будет заменена, сначала восстановите PFX в личное хранилище Windows:

```powershell
Import-PfxCertificate -FilePath <путь-к-PFX> -CertStoreLocation Cert:\CurrentUser\My -Password (Read-Host -AsSecureString)
```

## Выпуск

После создания сертификата скрипт выведет его thumbprint. Выпуск обеих
архитектур с подписью собственного EXE и DLL создаётся одной командой:

```powershell
.\BuildRelease.ps1 -Version 1.0 -CertificateThumbprint <thumbprint>
```

Архивы `win-x64` и `win-arm64` появляются в `Windows\artifacts\1.0`.
Если будет доступен надёжный timestamp-сервис, его URL передаётся через
`-TimestampUrl`; для самоподписанного закрытого тестирования он не обязателен.

Скрипт не изменяет подписи сторонних библиотек Microsoft и других поставщиков.
