#!/usr/bin/env bash
set -e

# Container and image naming
APP_NAME="code-server"
IMAGE_NAME="${APP_NAME}:latest"
LOCAL_IMAGE_NAME="localhost/${IMAGE_NAME}"

# Build the Docker image directly from embedded Dockerfile content
#    (tagged as "localhost/..." so no registry push is needed)
docker build -t "$LOCAL_IMAGE_NAME" -f - . << 'EOF'
FROM docker.io/codercom/code-server:4.138.0-trixie

# Switch to root to install packages
USER root

# Build arch (passed via --build-arg from the host) and Temurin JDK version
ARG ARCH=x64
ARG JDK_VERSION=25.0.4.1_1

# auxiliary variables
ARG JDK_MAJOR_VERSION=${JDK_VERSION%%.*}
ARG GITHUB_FOLDER_VERSION=${JDK_VERSION//_/+}

# Listen on port 8888 instead of code-server's default 8080
ENV PORT=8888 \
    CS_DISABLE_FILE_DOWNLOADS=true \
    ENTRYPOINTD=/entrypoint-scripts

# Install build tools and utilities
RUN apt update && \
    apt install -y --no-install-recommends \
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
    rm -rf /var/lib/apt/lists/*

# Install Eclipse Temurin OpenJDK
# Check https://adoptium.net/temurin/releases/?version=25 for the latest version if needed
RUN wget -O temurin-jdk${JDK_MAJOR_VERSION}.tar.gz https://github.com/adoptium/temurin${JDK_MAJOR_VERSION}-binaries/releases/download/jdk-${GITHUB_FOLDER_VERSION}/OpenJDK${JDK_MAJOR_VERSION}U-jdk_${ARCH}_linux_hotspot_${JDK_VERSION}.tar.gz && \
    mkdir -p /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION} && \
    tar -xzf temurin-jdk${JDK_MAJOR_VERSION}.tar.gz -C /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION} --strip-components=1 && \
    rm temurin-jdk${JDK_MAJOR_VERSION}.tar.gz && \
    # Set Java jdk as default via update-alternatives
    update-alternatives --install /usr/bin/java java /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/java 3000 && \
    update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/javac 3000 && \
    update-alternatives --set java /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/java && \
    update-alternatives --set javac /usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}/bin/javac

# Set default JAVA_HOME to Temurin JDK
ENV JAVA_HOME=/usr/lib/jvm/temurin-jdk${JDK_MAJOR_VERSION}

# Add NodeSource repo and install Node.js LTS
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt update && \
    apt install -y --no-install-recommends \
    nodejs \
    && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g npm@latest && \
    npm install -g @angular/cli

# add script to ENTRYPOINTD directory to always run at container startup
RUN mkdir -p /entrypoint-scripts && \
    touch /.password && \
    chmod a+rw /.password && \
    # keep in mind that the reset-password.sh will run on sh and not bash, that's why we have the \\\\n
    echo -n "#/usr/bin/env bash\n\nexport PASSWORD=\"\$(tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1)\"\n\necho \"\$PASSWORD\" > /.password\n\nsed -i \"s/^password:.*/password: \$PASSWORD/\" ~/.config/code-server/config.yaml\n\necho -n \"\\\\n\\\\n\\\\nURL: http://\$(curl --max-time 3 -sSf http://ifconfig.me 2>/dev/null || echo \"<IP NOT FOUND>\"):$PORT\\\\nPASSWORD: \$PASSWORD\\\\n\\\\n\\\\n\$(curl --max-time 3 -sSf https://ipinfo.io 2>/dev/null || echo \"<IP NOT FOUND>\")\\\\n\\\\n\\\\n\"\n\n" > /entrypoint-scripts/reset-password.sh && \
    chmod a+x /entrypoint-scripts/reset-password.sh

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
    printf '%s\n' "$(jq -e . ~/.local/share/code-server/User/settings.json 2>/dev/null || echo '{}')" | jq \
    '."keyboard.layout" = "00000816" | \
    ."spring.initializr.defaultLanguage" = "Java" | \
    ."git.openRepositoryInParentFolders" = "never" | \
    ."testing.automaticallyOpenTestResults" = "neverOpen" | \
    ."remote.autoForwardPortsSource" = "hybrid" | \
    ."workbench.colorTheme" = "Visual Studio Dark" ' \
    > ~/.local/share/code-server/User/settings.json

EOF

# Remove any existing container with the same name
docker rm -f "$APP_NAME" 2>/dev/null || true

# Run the freshly built container as the invoking user
#    (so files in the mounted host dirs aren't created as root when run via sudo).
#    --network=host exposes 8888 directly on the host, leaving 8080 free.
docker run --rm --detach --name "$APP_NAME" \
  --network=host \
  "$LOCAL_IMAGE_NAME"
