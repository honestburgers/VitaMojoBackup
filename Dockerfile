FROM mcr.microsoft.com/azure-powershell:latest
RUN pwsh -Command "Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted; Install-Module -Name Jwt -Scope AllUsers -Force"
WORKDIR /app
COPY azcopy .
COPY vita-mojo-backup.ps1 .
CMD ["pwsh", "/app/vita-mojo-backup.ps1"]