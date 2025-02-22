#!/bin/bash

RESOURCE_GROUP="ictcoe-edu" #az group list -o table

# ===========================================
# Gateway Pattern 실습환경 구성 스크립트
# ===========================================

# 사용법 출력
print_usage() {
   cat << EOF
사용법:
   $0 <userid>

설명:
   Gateway 패턴 실습을 위한 Azure 리소스를 생성합니다.
   리소스 이름이 중복되지 않도록 userid를 prefix로 사용합니다.

예제:
   $0 gappa     # gappa-gateway-sql 등의 리소스가 생성됨
EOF
}

# 유틸리티 함수
log() {
   local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
   echo "[$timestamp] $1" | tee -a $LOG_FILE
}

check_error() {
   if [ $? -ne 0 ]; then
       log "Error: $1"
       exit 1
   fi
}

# userid 파라미터 체크
if [ $# -ne 1 ]; then
   print_usage
   exit 1
fi

# userid 유효성 검사
if [[ ! $1 =~ ^[a-z0-9]+$ ]]; then
   echo "Error: userid는 영문 소문자와 숫자만 사용할 수 있습니다."
   exit 1
fi

# Azure CLI 로그인 체크
check_azure_cli() {
   log "Azure CLI 로그인 상태 확인 중..."
   az account show &> /dev/null
   if [ $? -ne 0 ]; then
       log "Azure CLI 로그인이 필요합니다."
       az login
       check_error "Azure 로그인 실패"
   fi
}

# 환경 변수 설정
echo "=== 1. 환경 변수 설정 ==="
USERID=$1
NAME="${USERID}-gateway"

AKS_NAME="${USERID}-aks"
ACR_NAME="${USERID}cr"
NAMESPACE="${USERID}-gateway"

LOG_FILE="deployment_${NAME}.log"

SERVICES=("scg" "inquiry" "tech" "billing")
SERVER_PORT="8080"

# MongoDB 설정
MONGODB_PORT=27017
MONGODB_USER="mongodb"
MONGODB_PASSWORD="Passw0rd"
MONGODB_DATABASE="supportdb"

GATEWAY_HOST=""

# Namespace 생성
setup_namespace() {
   log "Namespace 생성 중..."
   kubectl create namespace $NAMESPACE 2>/dev/null || true
   log "Namespace $NAMESPACE 생성 완료"
}

# 애플리케이션 빌드 및 이미지 생성
build_and_push_images() {
   log "애플리케이션 빌드 및 이미지 생성 중..."

   # AKS 자격 증명 가져오기
   az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME
   check_error "AKS 자격 증명 가져오기 실패"

   # ACR 로그인
   az acr login --name $ACR_NAME
   check_error "ACR 로그인 실패"

   for SERVICE in "${SERVICES[@]}"; do
       # 프로젝트 빌드
       ./gradlew $SERVICE:clean $SERVICE:build -x test
       check_error "$SERVICE Gradle 빌드 실패"

       log "Building $SERVICE image..."

       # Dockerfile 생성
       cat > $SERVICE/Dockerfile << EOF
FROM eclipse-temurin:17-jdk-alpine
COPY build/libs/${SERVICE}.jar app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
EOF

       # 이미지 빌드 및 푸시
       	cd "${SERVICE}"
       	az acr build \
       		--registry $ACR_NAME \
       		--image "gateway/${SERVICE}:v1" \
       		--file Dockerfile \
       		.
       	cd ..

       log "$SERVICE 이미지 생성 완료"
   done
}

# 기존 리소스 정리
cleanup_resources() {
   log "기존 리소스 정리 중..."

   # 기존 서비스 삭제
   for SERVICE in "${SERVICES[@]}"; do
       kubectl delete deployment $SERVICE -n $NAMESPACE 2>/dev/null || true
       log "$SERVICE 리소스 삭제 완료"
   done

   # MongoDB 리소스 삭제
   local DB_SERVICES=("inquiry" "tech" "billing")
   for SERVICE in "${DB_SERVICES[@]}"; do
       kubectl delete statefulset mongodb-$SERVICE -n $NAMESPACE 2>/dev/null || true
       log "$SERVICE MongoDB 리소스 삭제 완료"
   done

   # 잠시 대기하여 리소스가 완전히 삭제되도록 함
   log "리소스 정리 완료 대기 중..."
   sleep 10
}

# MongoDB 구성
setup_mongodb() {
   log "MongoDB 구성 중..."

   # 각 서비스별 MongoDB 배포
   local DB_SERVICES=("inquiry" "tech" "billing")

   for SERVICE in "${DB_SERVICES[@]}"; do
       cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
 name: mongodb-$SERVICE
 namespace: $NAMESPACE
spec:
 serviceName: mongodb-$SERVICE
 replicas: 1
 selector:
   matchLabels:
     app: mongodb-$SERVICE
 template:
   metadata:
     labels:
       app: mongodb-$SERVICE
   spec:
     containers:
     - name: mongodb
       image: mongo:latest
       ports:
       - containerPort: 27017
       env:
       - name: MONGO_INITDB_ROOT_USERNAME
         value: "$MONGODB_USER"
       - name: MONGO_INITDB_ROOT_PASSWORD
         value: "$MONGODB_PASSWORD"
       - name: MONGO_INITDB_DATABASE
         value: "${SERVICE}db"
---
apiVersion: v1
kind: Service
metadata:
 name: mongodb-$SERVICE
 namespace: $NAMESPACE
spec:
 selector:
   app: mongodb-$SERVICE
 ports:
 - port: $MONGODB_PORT
   targetPort: $MONGODB_PORT
 type: ClusterIP
EOF
       check_error "$SERVICE용 MongoDB 배포 실패"
   done
}

# ConfigMap 생성 함수
setup_configmap() {
    log "ConfigMap 생성 중..."

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $NAME-config
  namespace: $NAMESPACE
data:
  INQUIRY_SERVICE_HOST: "inquiry"
  INQUIRY_SERVICE_PORT: "${SERVER_PORT}"
  TECH_SERVICE_HOST: "tech"
  TECH_SERVICE_PORT: "${SERVER_PORT}"
  BILLING_SERVICE_HOST: "billing"
  BILLING_SERVICE_PORT: "${SERVER_PORT}"
EOF
    check_error "ConfigMap 생성 실패"
}

setup_services() {
    log "마이크로서비스 배포 중..."

    for i in "${!SERVICES[@]}"; do
        local SERVICE=${SERVICES[$i]}
        local PORT=${SERVER_PORT}
        local DB_NAME=""
        local YAML_FILE="service_${SERVICE}.yaml"

        # Gateway는 MongoDB가 필요없으므로 건너뜀
        if [ "$SERVICE" != "scg" ]; then
            DB_NAME="${SERVICE}db"
        fi

        # Create deployment YAML with all environment variables
        cat > $YAML_FILE << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SERVICE
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $SERVICE
  template:
    metadata:
      labels:
        app: $SERVICE
    spec:
      containers:
      - name: $SERVICE
        image: $ACR_NAME.azurecr.io/gateway/$SERVICE:v1
        imagePullPolicy: Always
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: $NAME-config
        env:
EOF

        # Gateway가 아닌 경우에만 MongoDB 환경변수 추가
        if [ "$SERVICE" != "scg" ]; then
            cat >> $YAML_FILE << EOF
        - name: MONGODB_HOST
          value: "mongodb-$SERVICE"
        - name: MONGODB_PORT
          value: "$MONGODB_PORT"
        - name: MONGODB_USER
          value: "$MONGODB_USER"
        - name: MONGODB_PASSWORD
          value: "$MONGODB_PASSWORD"
        - name: MONGODB_DB
          value: "$DB_NAME"
EOF
        fi

        # SERVER_PORT 환경변수 추가
        cat >> $YAML_FILE << EOF
        - name: SERVER_PORT
          value: "$PORT"
---
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE
  namespace: $NAMESPACE
spec:
  selector:
    app: $SERVICE
  ports:
  - port: $PORT
    targetPort: $PORT
  type: ClusterIP
EOF

        # Apply the configuration
        kubectl apply -f $YAML_FILE
        check_error "$SERVICE 서비스 배포 실패"

        # Clean up the temporary file
        rm $YAML_FILE
    done

    # Gateway Service만 LoadBalancer로 노출
    kubectl patch svc scg -n $NAMESPACE -p '{"spec": {"type": "LoadBalancer"}}'
    check_error "Gateway Service LoadBalancer 설정 실패"
}

# LoadBalancer IP 대기
wait_for_lb_ip() {
   log "LoadBalancer IP 할당 대기 중..."
   local retries=0
   local max_retries=10
   local APP_HOST=""

   while [ $retries -lt $max_retries ]; do
       APP_HOST=$(kubectl get svc scg -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
       if [ ! -z "$APP_HOST" ]; then
           log "LoadBalancer IP 할당 완료: $APP_HOST"
           GATEWAY_HOST=$APP_HOST
           return 0
       fi
       retries=$((retries + 1))
       log "IP 할당 대기 중... ($retries/$max_retries)"
       sleep 5
   done

   log "Error: LoadBalancer IP 할당 시간 초과"
   return 1
}

# 메인 실행 함수
main() {
   log "Gateway 패턴 실습환경 구성을 시작합니다..."

   # 사전 체크
   check_azure_cli

   # Namespace 생성
   setup_namespace

   # 빌드 및 이미지 생성
   build_and_push_images

   # 리소스 생성
   cleanup_resources
   setup_mongodb
   setup_configmap
   setup_services

   log "모든 리소스가 성공적으로 생성되었습니다."

   # 리소스 생성 완료 후 IP 대기
   wait_for_lb_ip
   check_error "LoadBalancer IP 할당 실패"

   log "=== Gateway 연결 정보 ==="
   log "Host: $GATEWAY_HOST"
   log "Port: ${SERVER_PORT}"

   log "=== 서비스 테스트 페이지 ==="
   log "http://$GATEWAY_HOST:${SERVER_PORT}/static/index.html"
}

# 스크립트 시작
main