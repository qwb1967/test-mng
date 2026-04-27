#!/bin/bash
set -euo pipefail

# Nacos Config (can be overridden by environment variables)
NACOS_ADDR="${NACOS_ADDR:-dev-nacos.imchenr1024.com}"
NACOS_USER="${NACOS_USER:-nacos}"
NACOS_PASS="${NACOS_PASS:-8f2598cdeedc4234b80c32424a7bd117}"
NAMESPACE="${NAMESPACE:-5143d5aa-cce6-43f7-bf9b-e422aaf7667d}"
DISCOVERY_IP="${DISCOVERY_IP:-127.0.0.1}"
DISCOVERY_CLUSTER="${DISCOVERY_CLUSTER:-QIANWENBO_LOCAL}"
DISCOVERY_CLUSTER_NAME="${DISCOVERY_CLUSTER_NAME:-QIANWENBO-LOCAL}"
DISCOVERY_GROUP="${DISCOVERY_GROUP:-QIANWENBO_LOCAL_GROUP}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_DIR="$ROOT_DIR/test-mng-service"

# ---- Detect Java 21 ----
# Required for both building (Maven) and running
if command -v /usr/libexec/java_home >/dev/null 2>&1; then
  JAVA_21_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
  if [ -n "$JAVA_21_HOME" ]; then
    export JAVA_HOME="$JAVA_21_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "☕ Found Java 21: $JAVA_HOME"
  else
    echo "⚠️ Warning: Java 21 not found via java_home. Trying system default."
  fi
fi

JAVA_BIN="$(command -v java)"
echo "☕ Using Java: $("$JAVA_BIN" -version 2>&1 | head -n 1)"

# ---- Build Services ----
echo "📦 Building all backend microservices with Maven (skipping tests)..."
cd "$SERVICE_DIR"
# Use -T 1C for faster parallel build if your machine supports it
mvn clean package -DskipTests
cd "$ROOT_DIR"

SERVICES=(
  "license-issuer:test-mng-license-issuer/target/test-mng-license-issuer.jar"
  "auth:test-mng-auth/target/test-mng-auth.jar"
  "system:test-mng-system/target/test-mng-system.jar"
  "task-center:test-mng-task-center/target/test-mng-task-center.jar"
  "functional:test-mng-functional/target/test-mng-functional.jar"
  "storage:test-mng-storage/target/test-mng-storage.jar"
  "api-test:test-mng-api-test/target/test-mng-api-test.jar"
  "api-test-execution:test-mng-api-test-execution/target/test-mng-api-test-execution.jar"
  "gateway:test-mng-gateway/target/test-mng-gateway.jar"
)

stop_service() {
  local service_name="$1"
  local jar_rel="$2"
  local jar_name
  jar_name="$(basename "$jar_rel")"

  if pgrep -f "$jar_name" >/dev/null 2>&1; then
    echo "🛑 Stopping ${service_name}..."
    pkill -f "$jar_name" || true
    sleep 2

    if pgrep -f "$jar_name" >/dev/null 2>&1; then
      echo "🛑 Force stopping ${service_name}..."
      pkill -9 -f "$jar_name" || true
    fi
  else
    echo "ℹ️  ${service_name} is not running."
  fi
}

start_service() {
  local service_name="$1"
  local jar_rel="$2"
  local jar_abs="$SERVICE_DIR/$jar_rel"
  local log_file="/tmp/${service_name}.log"

  if [ ! -f "$jar_abs" ]; then
    echo "❌ Missing JAR file: $jar_abs. Build failed?"
    return
  fi

  echo "🚀 Starting ${service_name}..."
  nohup "$JAVA_BIN" -Dspring.profiles.active=dev \
    -Dspring.cloud.nacos.server-addr="$NACOS_ADDR" \
    -Dspring.cloud.nacos.username="$NACOS_USER" \
    -Dspring.cloud.nacos.password="$NACOS_PASS" \
    -Dspring.cloud.nacos.config.namespace="$NAMESPACE" \
    -Dspring.cloud.nacos.discovery.namespace="$NAMESPACE" \
    -Dspring.cloud.nacos.discovery.group="$DISCOVERY_GROUP" \
    -Dspring.cloud.nacos.discovery.ip="$DISCOVERY_IP" \
    -Dspring.cloud.nacos.discovery.cluster-name="$DISCOVERY_CLUSTER_NAME" \
    -Dspring.cloud.nacos.discovery.metadata.cluster="$DISCOVERY_CLUSTER" \
    -jar "$jar_abs" > "$log_file" 2>&1 < /dev/null &
}

# 1. Stop all services
echo "🔄 Preparing to restart all microservices..."
for spec in "${SERVICES[@]}"; do
  stop_service "${spec%%:*}" "${spec#*:}"
done

# 2. Start all services
for spec in "${SERVICES[@]}"; do
  start_service "${spec%%:*}" "${spec#*:}"
done

echo "✅ All backend microservices built and restarted. Logs are in /tmp/*.log"

# 3. Tail all service logs in the background (prefixed with service name)
echo "📡 Streaming logs from all services. Press Ctrl+C to stop them all."
for spec in "${SERVICES[@]}"; do
  svc="${spec%%:*}"
  log_file="/tmp/${svc}.log"
  touch "$log_file"
  tail -n 0 -F "$log_file" 2>/dev/null \
    | awk -v s="$svc" '{ printf "[%s] %s\n", s, $0; fflush(); }' &
done

# 4. Wait for Ctrl+C, then stop all services and log tails
SHUTTING_DOWN=0
cleanup() {
  if [ "$SHUTTING_DOWN" -eq 1 ]; then
    return
  fi
  SHUTTING_DOWN=1
  echo ""
  echo "🧹 Received stop signal, stopping all log tails..."
  for spec in "${SERVICES[@]}"; do
    svc="${spec%%:*}"
    pkill -f "tail -n 0 -F /tmp/${svc}.log" 2>/dev/null || true
  done
  echo "🧹 Stopping all microservices..."
  for spec in "${SERVICES[@]}"; do
    stop_service "${spec%%:*}" "${spec#*:}"
  done
  echo "✅ All microservices stopped."
  exit 0
}
trap cleanup INT TERM

while true; do
  sleep 3600 &
  wait $!
done
