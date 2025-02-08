#!/bin/bash

SHARED_PREFIX="dg0100"  #실습 시 tiu-dgga로 변경

# ===========================================
# Gateway Pattern 실습환경 정리 스크립트
# ===========================================

# 사용법 출력
print_usage() {
   cat << EOF
사용법:
   $0 <userid>

설명:
   Gateway 패턴 실습을 위해 생성한 모든 Azure 리소스를 삭제합니다.

예제:
   $0 gappa     # gappa-gateway로 시작하는 모든 리소스 삭제
EOF
}

# 유틸리티 함수
log() {
   local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
   echo "[$timestamp] $1"
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

# 환경 변수 설정
NAME="${1}-gateway"
RESOURCE_GROUP="${SHARED_PREFIX}-rg"
AKS_NAME="${1}-aks"
ACR_NAME="${1}cr"
NAMESPACE="${1}-gateway"

SERVICES=("scg" "inquiry" "tech" "billing")

# 리소스 삭제 전 확인
confirm() {
   read -p "모든 리소스를 삭제하시겠습니까? (y/N) " response
   case "$response" in
       [yY][eE][sS]|[yY])
           return 0
           ;;
       *)
           echo "작업을 취소합니다."
           exit 1
           ;;
   esac
}

# AKS의 모든 리소스 삭제
cleanup_k8s_resources() {
   log "Kubernetes 리소스 삭제 중..."

   # AKS 자격 증명 가져오기
   az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

   # ConfigMap 삭제
   kubectl delete configmap $NAME-config -n $NAMESPACE 2>/dev/null || true

   # 서비스 삭제
   for SERVICE in "${SERVICES[@]}"; do
       kubectl delete service $SERVICE -n $NAMESPACE 2>/dev/null || true
       kubectl delete deployment $SERVICE -n $NAMESPACE 2>/dev/null || true
       log "$SERVICE 리소스 삭제 완료"
   done

   # MongoDB StatefulSet 및 서비스 삭제
   local DB_SERVICES=("inquiry" "tech" "billing")
   for SERVICE in "${DB_SERVICES[@]}"; do
       kubectl delete service mongodb-$SERVICE -n $NAMESPACE 2>/dev/null || true
       kubectl delete statefulset mongodb-$SERVICE -n $NAMESPACE 2>/dev/null || true
       log "$SERVICE MongoDB 리소스 삭제 완료"
   done

   # Namespace 삭제
   kubectl delete namespace $NAMESPACE 2>/dev/null || true

   log "Kubernetes 리소스 삭제 완료"
}

# ACR의 이미지 삭제
cleanup_acr_images() {
   log "ACR 이미지 삭제 중..."

   # ACR 로그인
   az acr login --name $ACR_NAME

   # 각 서비스의 이미지 삭제
   for SERVICE in "${SERVICES[@]}"; do
       az acr repository delete --name $ACR_NAME --image $NAME-$SERVICE:latest --yes 2>/dev/null || true
       log "$SERVICE 이미지 삭제 완료"
   done

   log "ACR 이미지 삭제 완료"
}

# 메인 실행 함수
main() {
   log "리소스 정리를 시작합니다..."

   # 삭제 전 확인
   confirm

   # Kubernetes 리소스 삭제
   cleanup_k8s_resources

   # ACR 이미지 삭제
   cleanup_acr_images

   log "모든 리소스가 정리되었습니다."

   # 남은 리소스 확인
   log "=== 남은 리소스 확인 ==="
   kubectl get all -n $NAMESPACE
}

# 스크립트 시작
main