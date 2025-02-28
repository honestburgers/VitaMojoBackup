FROM mcr.microsoft.com/azure-powershell:latest
WORKDIR /app
COPY vita-mojo-backup.ps1 .
COPY azcopy .
CMD ["pwsh", "/app/vita-mojo-backup.ps1"]