#!/usr/bin/env bash
set -euo pipefail

# Container and image naming
APP_NAME="code-server"
IMAGE_NAME="${APP_NAME}:latest"
LOCAL_IMAGE_NAME="localhost/${IMAGE_NAME}"

# Build the Docker image directly from the complete embedded Dockerfile.
# This is intentionally a second, synchronized single-file implementation.
docker build -t "$LOCAL_IMAGE_NAME" -f - . << 'CONTAINERFILE'
FROM docker.io/codercom/code-server:4.138.0-trixie

# Switch to root to install packages
USER root

# Build arch (passed via --build-arg from the host) and Temurin JDK version
ARG JDK_ARCH=x64
ARG JDK_VERSION=25.0.4.1_1

# auxiliary variables
ARG JDK_MAJOR_VERSION=${JDK_VERSION%%.*}
ARG GITHUB_FOLDER_VERSION=${JDK_VERSION//_/+}

# Listen on port 8888 instead of code-server's default 8080
ENV PORT=8888 \
    CS_DISABLE_FILE_DOWNLOADS=true \
    ENTRYPOINTD=/entrypoint-scripts

# Install build tools and utilities
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    maven \
    gradle \
    git \
    curl \
    tar \
    unzip \
    wget \
    ca-certificates \
    gnupg \
    iproute2 \
    dnsutils \
    iputils-ping \
    jq \
    && \
    apt-get clean \
    && \
    rm -rf /var/lib/apt/lists/*

# Install Eclipse Temurin OpenJDK
# Check https://adoptium.net/temurin/releases/?version=25 for the latest version if needed
RUN set -eu; \
    JDK_ARCHIVE="OpenJDK${JDK_MAJOR_VERSION}U-jdk_${JDK_ARCH}_linux_hotspot_${JDK_VERSION}.tar.gz"; \
    JDK_URL="https://github.com/adoptium/temurin${JDK_MAJOR_VERSION}-binaries/releases/download/jdk-${GITHUB_FOLDER_VERSION}/${JDK_ARCHIVE}"; \
    curl -fsSL --retry 3 --retry-all-errors -o "/tmp/${JDK_ARCHIVE}" "${JDK_URL}"; \
    curl -fsSL --retry 3 --retry-all-errors -o "/tmp/${JDK_ARCHIVE}.sha256.txt" "${JDK_URL}.sha256.txt"; \
    EXPECTED_SHA256="$(awk '{print $1}' "/tmp/${JDK_ARCHIVE}.sha256.txt")"; \
    test -n "${EXPECTED_SHA256}"; \
    printf '%s  %s\n' "${EXPECTED_SHA256}" "/tmp/${JDK_ARCHIVE}" | sha256sum -c -; \
    mkdir -p "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}"; \
    tar -xzf "/tmp/${JDK_ARCHIVE}" -C "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}" --strip-components=1; \
    rm -f "/tmp/${JDK_ARCHIVE}" "/tmp/${JDK_ARCHIVE}.sha256.txt"; \
    # Set Java jdk as default via update-alternatives
    update-alternatives --install /usr/bin/java java "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/java" 3000; \
    update-alternatives --install /usr/bin/javac javac "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/javac" 3000; \
    update-alternatives --set java "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/java"; \
    update-alternatives --set javac "/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/javac"

# Set default JAVA_HOME to Temurin JDK
ENV JAVA_HOME=/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}

# Add NodeSource repo and install Node.js LTS
RUN set -eu; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/nodesource-repo.gpg.key https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key; \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource-repo.gpg.key; \
    rm -f /tmp/nodesource-repo.gpg.key; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

ARG NPM_VERSION=11.6.0
ARG ANGULAR_CLI_VERSION=20.3.0

RUN npm install --global "npm@${NPM_VERSION}" "@angular/cli@${ANGULAR_CLI_VERSION}" && \
    node --version && \
    npm --version && \
    ng version

# Add a startup hook without introducing a second file dependency.
RUN mkdir -p /entrypoint-scripts && \
    install -o coder -g coder -m 0600 /dev/null /.password && \
    printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '' \
    'umask 077' \
    'PASSWORD_FILE=/.password' \
    'CONFIG_FILE="${HOME:-/home/coder}/.config/code-server/config.yaml"' \
    'CONFIG_DIRECTORY="$(dirname "${CONFIG_FILE}")"' \
    'PASSWORD="$(od -An -N30 -v -tx1 /dev/urandom | tr -d "[:space:]")"' \
    '' \
    'mkdir -p "${CONFIG_DIRECTORY}"' \
    'CONFIG_TEMP="${CONFIG_FILE}.$$"' \
    'if [ -f "${CONFIG_FILE}" ]; then' \
    '    sed -e "/^[[:space:]]*hashed-password:/d" -e "s/^password:.*/password: ${PASSWORD}/" "${CONFIG_FILE}" > "${CONFIG_TEMP}"' \
    '    if ! grep -q "^password:" "${CONFIG_TEMP}"; then' \
    '        printf "password: %s\\n" "${PASSWORD}" >> "${CONFIG_TEMP}"' \
    '    fi' \
    'else' \
    '    printf "auth: password\\npassword: %s\\ncert: false\\n" "${PASSWORD}" > "${CONFIG_TEMP}"' \
    'fi' \
    'mv -f "${CONFIG_TEMP}" "${CONFIG_FILE}"' \
    'chmod 600 "${CONFIG_FILE}"' \
    '' \
    'printf "%s\\n" "${PASSWORD}" > "${PASSWORD_FILE}"' \
    'chmod 600 "${PASSWORD_FILE}"' \
    '' \
    'PUBLIC_IP="<IP NOT FOUND>"' \
    'if VALUE="$(curl --max-time 3 -sSf http://ifconfig.me 2>/dev/null)" && [ -n "${VALUE}" ]; then' \
    '    PUBLIC_IP="${VALUE}"' \
    'fi' \
    'IP_INFO="<IP NOT FOUND>"' \
    'if VALUE="$(curl --max-time 3 -sSf https://ipinfo.io 2>/dev/null)" && [ -n "${VALUE}" ]; then' \
    '    IP_INFO="${VALUE}"' \
    'fi' \
    '' \
    'printf "\\n\\n\\nURL: http://%s:%s\\nPASSWORD: %s\\n\\n\\n%s\\n\\n\\n" "${PUBLIC_IP}" "${PORT:-8888}" "${PASSWORD}" "${IP_INFO}"' \
    > /entrypoint-scripts/reset-password.sh && \
    chmod 0755 /entrypoint-scripts/reset-password.sh

# Create workspace
RUN mkdir -p /workspace && chown -R coder:coder /workspace

# Switch back to non-root user
USER coder

WORKDIR /workspace

# Install java extensions and spring boot extensions
RUN code-server --force --install-extension vscjava.vscode-java-pack && \
    code-server --force --install-extension VMware.vscode-boot-dev-pack

# Merge defaults into the code-server settings.json via jq
# (keyboard layout + color theme), falling back to '{}' if absent
RUN mkdir -p ~/.local/share/code-server/User && \
    if [ -f ~/.local/share/code-server/User/settings.json ]; then \
        jq -e . ~/.local/share/code-server/User/settings.json; \
    else \
        printf '{}\n'; \
    fi | jq \
    '."keyboard.layout" = "00000816" | \
     ."spring.initializr.defaultLanguage" = "Java" | \
     ."git.openRepositoryInParentFolders" = "never" | \
     ."testing.automaticallyOpenTestResults" = "neverOpen" | \
     ."remote.autoForwardPortsSource" = "hybrid" | \
     ."workbench.colorTheme" = "Visual Studio Dark" ' \
     > ~/.local/share/code-server/User/settings.json.tmp && \
    mv -f ~/.local/share/code-server/User/settings.json.tmp ~/.local/share/code-server/User/settings.json
CONTAINERFILE

# Remove any existing container with the same name
docker rm -f "$APP_NAME" 2>/dev/null || true

# Host networking is intentional: development applications may expose ports.
docker run --rm --detach --name "$APP_NAME" \
  --network=host \
  "$LOCAL_IMAGE_NAME"
