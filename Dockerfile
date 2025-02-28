FROM mcr.microsoft.com/powershell:latest
WORKDIR /app
COPY vita-mojo-backup.ps1 .
CMD ["pwsh", "/app/vita-mojo-backup.ps1"]