# 애플리케이션 개발자 가이드

이 문서는 애플리케이션 개발자를 위한 가이드입니다. 인프라 관리자는 [INFRA.md](INFRA.md)를 참조하세요.

## 목차

1. [빠른 시작](#빠른-시작)
2. [앱 추가하기](#앱-추가하기)
3. [compose.base.yml 작성](#composebaseyml-작성)
4. [앱 배포](#앱-배포)
5. [환경변수](#환경변수)
6. [데이터베이스 연결](#데이터베이스-연결)
7. [모니터링 설정](#모니터링-설정)
8. [CI/CD 연동](#cicd-연동)
9. [문제 해결](#문제-해결)

---

## 빠른 시작

### 새 앱의 템플릿 추가

```bash
# 앱 추가 (이름: myapp, 포트: 8080)
./app create myapp 8080

# 생성된 파일 확인
ls -la apps/myapp/
# .env              - APP_NAME, APP_PORT
# compose.base.yml  - 앱 정의 (수정 필요)
# compose.attach.yml - 인프라 연결 (자동 생성)
```

### compose.base.yml 수정

```bash
vim apps/myapp/compose.base.yml
```

```yaml
services:
  app-server:
    image: ghcr.io/your-org/myapp:latest
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - DATABASE_URL=jdbc:mysql://central-mysql:3306/myapp
    # volumes:
    #   - ./data:/app/data
```

### 앱 시작

```bash
./app start myapp
```

### 접속 확인

```
https://myapp.app.example.com
```

---

## 앱 템플릿 추가하기

### `./app create <name> <port>`

새로운 앱을 스캐폴딩합니다.

```bash
./app create myapp 8080
```

**검증 규칙**:
- 이름: 소문자, 숫자, 하이픈(-)만 사용
- 중복 불가: 이미 존재하는 앱 이름 사용 불가
- 포트: 1-65535 범위

**생성되는 파일**:

1. `apps/<name>/.env`:
   ```env
   APP_NAME=myapp
   APP_PORT=8080
   ```

2. `apps/<name>/compose.attach.yml` (자동 생성, 수정 불필요):
   ```yaml
   services:
     app-server:
       extends:
         file: ../central-infra/fragments/app-attach-base.yml
         service: app-server
   ```

3. `apps/<name>/compose.base.yml` (수정 필요):
   ```yaml
   services:
     app-server:
       image: your-image:latest
       # environment:
       #   - KEY=value
       # volumes:
       #   - ./data:/app/data
   ```

---

## compose.base.yml 작성

### 기본 구조

```yaml
services:
  app-server:
    image: ghcr.io/your-org/myapp:latest
    
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - DATABASE_URL=jdbc:mysql://central-mysql:3306/myapp
      - DATABASE_USERNAME=root
      - DATABASE_PASSWORD=${MYSQL_ROOT_PASSWORD}
    
    volumes:
      - ./data:/app/data
    
    # 선택사항: Prometheus 메트릭
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=8080"
```

### 주의사항

**DO** ✅:
- `image`에 GHCR 이미지 사용
- 환경변수로 설정 주입
- `central-mysql`, `central-redis` 등으로 다른 서비스 접근

**DON'T** ❌:
- `ports` 정의하지 마세요 (Traefik이 라우팅)
- `networks` 정의하지 마세요 (compose.attach.yml에서 처리)
- 도메인 하드코딩하지 마세요 (.env에서 관리)

### Spring Boot 예시

```yaml
services:
  app-server:
    image: ghcr.io/your-org/myapp:latest
    
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - SPRING_DATASOURCE_URL=jdbc:mysql://central-mysql:3306/myapp
      - SPRING_DATASOURCE_USERNAME=root
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,info,prometheus
      - MANAGEMENT_METRICS_EXPORT_PROMETHEUS_ENABLED=true
    
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=8080"
```

### Node.js 예시

```yaml
services:
  app-server:
    image: ghcr.io/your-org/nodeapp:latest
    
    environment:
      - NODE_ENV=production
      - DATABASE_HOST=central-mysql
      - DATABASE_PORT=3306
      - REDIS_HOST=central-redis
      - REDIS_PORT=6379
    
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=3000"
```

---

## 앱 배포

### 수동 배포

```bash
# 이미지 pull 후 재시작
./app upgrade myapp
```

**업그레이드 과정**:
1. 점검 페이지로 전환 (사용자는 점검 안내 페이지 확인)
2. 새 이미지 pull
3. 컨테이너 교체
4. 라우팅 복구

### 롤백

```bash
# compose.base.yml에서 이전 태그로 변경
vim apps/myapp/compose.base.yml
# image: ghcr.io/your-org/myapp:abc1234  # 커밋 SHA 태그

# 업그레이드 실행
./app upgrade myapp
```

---

## 환경변수

### 사용 가능한 변수

| 변수 | 출처 | 설명 |
|------|------|------|
| `BASE_DOMAIN` | `~/infra/.env` | 도메인 (예: example.com) |
| `APP_NAME` | `apps/<name>/.env` | 앱 이름 |
| `APP_PORT` | `apps/<name>/.env` | 앱 포트 |
| `MYSQL_ROOT_PASSWORD` | `~/infra/.env` | MySQL 루트 비밀번호 |
| `GF_SECURITY_ADMIN_PASSWORD` | `~/infra/.env` | Grafana 관리자 비밀번호 |

### 변수 참조

`compose.base.yml`에서 변수 사용:

```yaml
services:
  app-server:
    environment:
      - APP_DOMAIN=${APP_NAME}.app.${BASE_DOMAIN}
      - DATABASE_PASSWORD=${MYSQL_ROOT_PASSWORD}
```

### 비밀번호 관리

민감한 정보는 별도 `.env` 파일에 저장 (`.gitignore`에 추가됨):

```bash
# apps/myapp/.env에 추가
vim apps/myapp/.env
```

```env
APP_NAME=myapp
APP_PORT=8080
API_KEY=secret-key-here
```

---

## 데이터베이스 연결

### MySQL 연결

**데이터베이스 생성** (최초 1회):

```bash
# MySQL 컨테이너 접속
docker exec -it central-mysql mysql -u root -p

# 데이터베이스 생성
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

**앱 설정**:

```yaml
# apps/myapp/compose.base.yml
services:
  app-server:
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://central-mysql:3306/myapp
      - SPRING_DATASOURCE_USERNAME=root
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_ROOT_PASSWORD}
```

### 연결 확인

```bash
# 앱 컨테이너에서 MySQL ping
docker exec -it app-myapp-server ping central-mysql
```

---

## 모니터링 설정

### Prometheus 메트릭 노출

**Spring Boot**:

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  metrics:
    export:
      prometheus:
        enabled: true
```

**compose.base.yml**:

```yaml
services:
  app-server:
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=8080"
```

### Grafana 대시보드

1. `https://central.{BASE_DOMAIN}/grafana` 접속
2. Dashboards → Import
3. Spring Boot 대시보드 ID: 12900

### 로그 확인

Grafana → Explore → Loki:

```logql
{container_name="app-myapp-server"}
| |= "error"
```

---

## CI/CD 연동

### GitHub Actions 예시

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Build image
        run: docker build -t ghcr.io/${{ github.repository }}:latest .
      
      - name: Push to GHCR
        run: |
          echo ${{ secrets.GITHUB_TOKEN }} | docker login ghcr.io -u ${{ github.actor }} --password-stdin
          docker push ghcr.io/${{ github.repository }}:latest
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: production  # 수동 승인 필요
    steps:
      - name: Deploy to server
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_KEY }}
          script: |
            cd ~/infra
            ./app upgrade myapp
```

### GitHub Environment 설정

1. Settings → Environments → New environment: `production`
2. Add required reviewers (배포 승인자)
3. Secrets 설정:
   - `SERVER_HOST`: 서버 IP
   - `SERVER_USER`: SSH 사용자
   - `SSH_KEY`: SSH 개인키

---

## 문제 해결

### 앱이 시작되지 않음

```bash
# 로그 확인
docker logs app-myapp-server

# compose 설정 확인
docker compose \
  --env-file ~/infra/.env \
  --env-file apps/myapp/.env \
  -f apps/myapp/compose.base.yml \
  -f apps/myapp/compose.attach.yml \
  config
```

### 접속 불가

1. **컨테이너 상태 확인**:
   ```bash
   ./app list
   ```

2. **Traefik 라우팅 확인**:
   ```bash
   docker logs central-traefik | grep myapp
   ```

3. **DNS 확인**:
   ```bash
   dig myapp.app.example.com
   ```

### 데이터베이스 연결 실패

```bash
# MySQL 실행 확인
docker ps | grep mysql

# MySQL 로그 확인
docker logs central-mysql

# 네트워크 연결 확인
docker exec app-myapp-server ping central-mysql
```

### 업그레이드 실패

업그레이드가 실패해도 점검 페이지는 자동으로 복구됩니다 (`trap EXIT`).

```bash
# 실패 원인 확인
docker logs app-myapp-server

# 수동 복구
./app upgrade myapp
```

---

## CLI 명령어 요약

### 앱 관리

| 명령어 | 설명 |
|--------|------|
| `./app create <name> <port>` | 새 앱 템플릿을 이름으로 추가 |
| `./app remove <name>` | 앱 제거 (확인 필요) |
| `./app start <name>` | 앱 시작 |
| `./app stop <name>` | 앱 중지 |
| `./app upgrade <name>` | 앱 업그레이드 |
| `./app list` | 앱 목록 및 상태 |

### 파일 구조

```
apps/<name>/
├── .env              # APP_NAME, APP_PORT (+ 비밀번호)
├── compose.base.yml  # 앱 정의 (이미지, 환경변수)
└── compose.attach.yml # 인프라 연결 (자동 생성)
```

---

## 참고

- [INFRA.md](INFRA.md) - 인프라 운영 가이드
- [plans/IMPL.md](../plans/IMPL.md) - 구현 계획서
