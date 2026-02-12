#!/bin/bash
# Build frontend using Docker and deploy to Linux station
# This avoids Node.js version issues on the host

set -e

# Configuration
LINUX_HOST="${LINUX_HOST:-192.168.1.33}"
LINUX_USER="${LINUX_USER:-azyben}"
SERVER="${LINUX_USER}@${LINUX_HOST}"
REMOTE_BUILD_DIR="/tmp/signoz-frontend-build"
LOCAL_REPO="/Users/jcyangzh/projects/signoz-debug"

echo "🎨 Building frontend using Docker on linux station: $SERVER..."
echo ""

# Check if we're on the correct branch
CURRENT_BRANCH=$(git -C ${LOCAL_REPO} rev-parse --abbrev-ref HEAD)
echo "📌 Current branch: ${CURRENT_BRANCH}"
echo ""

# Create tarball of frontend only
echo "📦 Packaging frontend source code..."
TEMP_TAR="/tmp/signoz-frontend.tar.gz"
# Use COPYFILE_DISABLE to avoid macOS extended attributes
COPYFILE_DISABLE=1 tar -czf ${TEMP_TAR} \
    -C ${LOCAL_REPO} \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='build' \
    --exclude='.next' \
    --exclude='.yarn/cache' \
    --exclude='.DS_Store' \
    frontend
echo "✅ Frontend source packaged"
echo ""

# Clean up old build directory on remote
echo "🧹 Preparing build directory on remote..."
ssh ${SERVER} "rm -rf ${REMOTE_BUILD_DIR} && mkdir -p ${REMOTE_BUILD_DIR}"
echo "✅ Build directory ready"
echo ""

# Copy frontend source to remote
echo "📤 Copying frontend source to linux station..."
scp ${TEMP_TAR} ${SERVER}:/tmp/signoz-frontend.tar.gz
ssh ${SERVER} "cd ${REMOTE_BUILD_DIR} && tar -xzf /tmp/signoz-frontend.tar.gz"
rm ${TEMP_TAR}
ssh ${SERVER} "rm /tmp/signoz-frontend.tar.gz"
echo "✅ Frontend source copied"
echo ""

# Build frontend using Docker with Node 22
echo "🔨 Building frontend in Docker container..."
ssh ${SERVER} << 'ENDSSH'
set -e
BUILD_DIR="/tmp/signoz-frontend-build"

# Create Dockerfile for frontend build
cat > ${BUILD_DIR}/Dockerfile.build << 'DOCKERFILE'
FROM node:22-alpine AS builder
WORKDIR /build

# Copy all files first (needed for postinstall scripts)
COPY frontend/ ./

# Install dependencies
RUN yarn install --frozen-lockfile || yarn install

# Build
RUN yarn build

# Output stage - just keep the build
FROM alpine:3.20
COPY --from=builder /build/build /frontend/build
DOCKERFILE

# Build the frontend using Docker
echo "Building frontend in Docker..."
cd ${BUILD_DIR}
docker build -f Dockerfile.build -t signoz-frontend-builder .

# Extract the build output
echo "Extracting build output..."
docker create --name temp-frontend signoz-frontend-builder
docker cp temp-frontend:/frontend/build ${BUILD_DIR}/frontend/build
docker rm temp-frontend

echo "✅ Frontend built"
ENDSSH
echo ""

# Create a patched Docker image
echo "🐳 Patching frontend into Docker image..."
ssh ${SERVER} << 'ENDSSH'
set -e
BUILD_DIR="/tmp/signoz-frontend-build"

# Create Dockerfile for patching
cat > ${BUILD_DIR}/Dockerfile.patch << 'DOCKERFILE'
FROM signoz/signoz:v0.109.2-timestamp-fix-amd64

# Remove old frontend
RUN rm -rf /etc/signoz/web/*

# Copy new frontend
COPY frontend/build/ /etc/signoz/web/
DOCKERFILE

# Build the patched image
echo "Building patched image..."
cd ${BUILD_DIR}
docker build -f Dockerfile.patch -t signoz/signoz:v0.109.2-tooltip-fix-amd64 .

# Tag as latest
docker tag signoz/signoz:v0.109.2-tooltip-fix-amd64 signoz/signoz:v0.109.2-tooltip-fix

echo "✅ Docker image patched"
ENDSSH
echo ""

# Update docker-compose.yml
echo "📝 Updating docker-compose.yml..."
ssh ${SERVER} << 'ENDSSH'
cd /data/signoz
# Update image tag
sed -i 's|image: signoz/signoz:.*|image: signoz/signoz:v0.109.2-tooltip-fix-amd64|g' docker-compose.yml
echo "✅ docker-compose.yml updated"
ENDSSH
echo ""

# Restart SigNoz service
echo "🔄 Restarting SigNoz service..."
ssh ${SERVER} "cd /data/signoz && docker compose up -d signoz"
echo "✅ SigNoz service restarted"
echo ""

# Clean up
echo "🧹 Cleaning up build directory..."
ssh ${SERVER} "rm -rf ${REMOTE_BUILD_DIR}"
echo "✅ Build directory cleaned"
echo ""

# Wait for service
echo "⏳ Waiting for SigNoz to be healthy..."
sleep 10
ssh ${SERVER} "docker ps --filter name=signoz --format '{{.Names}}\t{{.Status}}'"
echo ""

echo "✅ Frontend patch deployed successfully!"
echo "🌐 Access SigNoz UI at: http://${LINUX_HOST}:8080"
echo ""
echo "📝 The tooltip fix should now be applied."
echo "   Tooltip will now show all series with '(no data)' for missing values."
echo ""
echo "💡 Tip: Clear your browser cache (Ctrl+Shift+R) before testing"
