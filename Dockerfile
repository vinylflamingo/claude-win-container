# Claude Code container — Windows Server Core base, project-agnostic.
#
# Build args let consumers pin versions.
# Runtime: bind-mount a project at C:/workspace and per-project state at C:/claude-data.

ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019
FROM ${BASE_IMAGE}

ARG CLAUDE_NODE_VERSION=20.18.0
ARG CLAUDE_GIT_URL=https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/MinGit-2.45.2-64-bit.zip
ARG CLAUDE_CODE_VERSION=latest

# Promote ARGs to ENV so PowerShell can read them via $env:VAR at runtime.
ENV CLAUDE_NODE_VERSION=${CLAUDE_NODE_VERSION} \
    CLAUDE_GIT_URL=${CLAUDE_GIT_URL} \
    CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}

# Force TLS 1.2 — Server Core's PowerShell defaults to TLS 1.0/1.1 which nodejs.org and GitHub reject.
SHELL ["powershell", "-NoProfile", "-NoLogo", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;"]

# Node.js (zip install — avoids Chocolatey dependency)
RUN $ver = $env:CLAUDE_NODE_VERSION; \
    $url = ('https://nodejs.org/dist/v{0}/node-v{0}-win-x64.zip' -f $ver); \
    Write-Host ('Downloading Node.js ' + $ver + ' from ' + $url); \
    Invoke-WebRequest -Uri $url -OutFile C:\node.zip -UseBasicParsing; \
    Expand-Archive C:\node.zip -DestinationPath C:\; \
    Rename-Item ('C:\node-v{0}-win-x64' -f $ver) C:\nodejs; \
    Remove-Item C:\node.zip; \
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'); \
    [Environment]::SetEnvironmentVariable('Path', ('C:\nodejs;' + $machinePath), 'Machine')

# MinGit (Git for Windows, CLI-only, ~50MB)
RUN $url = $env:CLAUDE_GIT_URL; \
    Write-Host ('Downloading MinGit from ' + $url); \
    Invoke-WebRequest -Uri $url -OutFile C:\git.zip -UseBasicParsing; \
    Expand-Archive C:\git.zip -DestinationPath C:\git; \
    Remove-Item C:\git.zip; \
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'); \
    [Environment]::SetEnvironmentVariable('Path', ('C:\git\cmd;' + $machinePath), 'Machine')

# Claude Code CLI (npm global)
RUN $pkg = '@anthropic-ai/claude-code@' + $env:CLAUDE_CODE_VERSION; \
    Write-Host ('Installing ' + $pkg); \
    npm install -g $pkg

# Bind-mount targets — must exist before Docker mounts over them
RUN New-Item -ItemType Directory -Force -Path C:\workspace, C:\claude-data, C:\command-history, C:\claude-auth | Out-Null

COPY entrypoint.ps1 C:/entrypoint.ps1

# Forward slashes — Docker's Dockerfile parser treats `\` as an escape character,
# so `C:\workspace` would silently become `C:workspace`. Forward slashes are safe and
# Windows accepts them. (Paths inside RUN PowerShell commands are unaffected.)
ENV CLAUDE_CONFIG_DIR=C:/claude-data \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

WORKDIR C:/workspace
ENTRYPOINT ["powershell", "-NoProfile", "-NoLogo", "-File", "C:\\entrypoint.ps1"]
CMD ["claude"]
