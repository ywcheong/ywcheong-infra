# 인프라 운영 가이드

이 문서는 인프라 관리자를 위한 운영 가이드입니다. 애플리케이션 개발자는 [APP.md](APP.md)를 참조하세요.

## 목차

1. [시작하기](#시작하기)
2. [CLI 명령어](#cli-명령어)
3. [디렉터리 구조](#디렉터리-구조)
4. [서비스 구성](#서비스-구성)
5. [네트워크 아키텍처](#네트워크-아키텍처)
6. [TLS/SSL 설정](#tlsssl-설정)
7. [모니터링](#모니터링)
8. [문제 해결](#문제-해결)
9. [마이그레이션](#마이그레이션)

---

## 시작하기

### 사전 요구사항

- Docker Engine 24.0+
- Docker Compose v2+
- 포트 80, 443 사용 가능
- Cloudflare 계정 (DNS 및 Origin Certificate용)

### 초기 설정

```bash
# 1. 저장소 클론
git clone <repository-url>
cd ywcheong-infra

# 2. 환경 설정
./infra setup

# 3. .env 파일 수정
# BASE_DOMAIN을 실제 도메인으로 변경
vim .env

# 4. Cloudflare Origin Certificate 배치
# Cloudflare 대시보드에서 Origin Certificate 발급 후:
cp origin.pem central-infra/certs/
cp origin.key central-infra/certs/

# 5. Cloudflare DNS 설정
# 타입    이름       값                   프록시
# A       @          {서버 IP}            Proxied (🟠)
# A       central    {서버 IP}            Proxied (🟠)
# CNAME   *.app      example.com          Proxied (🟠)

# 6. SSL/TLS 모드 설정
# Cloudflare SSL/TLS → Overview → Full (strict)

# 7. 인프라 시작
./infra start
```

---

## CLI 명령어

### `./infra` - 중앙 인프라 관리

#### `./infra setup`

최초 환경 구성 (멱등적 실행 가능)

```bash
./infra setup
```

수행 작업:
- Docker 설치 및 데몬 실행 확인
- 포트 80/443 사용 가능 여부 확인
- `central-net` 외부 네트워크 생성
- 디렉터리 구조 생성
- `.env` 템플릿 생성 (없는 경우)

#### `./infra start`

중앙 인프라 및 모든 앱 시작

```bash
./infra start
```

수행 작업:
1. `central-infra/compose.yml` 서비스 기동
2. `apps/` 디렉터리의 모든 앱 순차적 기동

#### `./infra stop`

모든 서비스 중지 (볼륨 데이터 보존)

```bash
./infra stop
```

수행 작업:
1. 모든 앱 역순으로 중지
2. 중앙 인프라 중지

#### `./infra status`

모든 컨테이너 상태 확인

```bash
./infra status
```

출력 예시:
```
=== Central Infrastructure ===
central-traefik      running    0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
central-mysql        running    3306/tcp
central-prometheus   running    9090/tcp
central-grafana      running    3000/tcp
central-loki         running    3100/tcp
central-promtail     running    9080/tcp
central-maintenance  running    80/tcp

=== Applications ===
myapp                running    myapp.app.example.com
otherapp             stopped    -
```

#### `./infra archive`

마이그레이션용 아카이브 생성

```bash
./infra archive
```

수행 작업:
1. 확인 프롬프트 표시
2. 모든 서비스 중지
3. tarball 생성: `infra-backup-YYYYMMDD-HHMMSS.tar.gz`
   - `~/infra` (설정 파일)
   - `/var/lib/docker/volumes/` (데이터 볼륨)

---

## 디렉터리 구조

```
~/infra/
├── .env                      # BASE_DOMAIN (도메인의 유일한 출처)
├── infra                     # 인프라 관리 CLI
├── app                       # 앱 관리 CLI
│
├── central-infra/
│   ├── compose.yml           # 중앙 서비스 정의
│   ├── traefik/
│   │   ├── traefik.yml       # Traefik 정적 설정
│   │   └── dynamic/          # 동적 라우팅 (파일 프로바이더)
│   ├── certs/
│   │   ├── origin.pem        # Cloudflare Origin Certificate
│   │   └── origin.key
│   ├── prometheus/
│   │   └── prometheus.yml    # 메트릭 스크랩 설정
│   ├── loki/
│   │   └── loki-config.yml   # 로그 집계 설정
│   ├── promtail/
│   │   └── promtail-config.yml # 로그 수집 설정
│   ├── grafana/
│   │   └── provisioning/
│   │       └── datasources/  # 데이터소스 자동 구성
│   ├── maintenance/
│   │   └── index.html        # 점검 페이지
│   └── fragments/
│       └── app-attach-base.yml # 앱 인프라 연결 SSOT
│
└── apps/
    ├── myapp/
    │   ├── .env              # APP_NAME, APP_PORT
    │   ├── compose.base.yml  # 앱 정의
    │   └── compose.attach.yml # 인프라 연결
    └── otherapp/
        └── ...
```

---

## 서비스 구성

### Traefik (리버스 프록시)

- **이미지**: traefik:v3.0
- **포트**: 80 (HTTP), 443 (HTTPS)
- **기능**:
  - Docker 컨테이너 자동 감지 (라벨 기반)
  - 파일 프로바이더 (점검 페이지 전환)
  - TLS 종료 (Origin Certificate)
  - HTTP→HTTPS 리다이렉트

**대시보드 접근**: `https://traefik.{BASE_DOMAIN}`

### MySQL (데이터베이스)

- **이미지**: mysql:8.0
- **볼륨**: `mysql-data`
- **접속**: 앱에서 `central-mysql:3306`

### Prometheus (메트릭 수집)

- **이미지**: prom/prometheus:latest
- **포트**: 9090
- **수집 대상**:
  - Traefik 메트릭
  - Node Exporter
  - MySQL Exporter
  - Spring Actuator 앱

**접근**: `https://central.{BASE_DOMAIN}/prometheus`

### Grafana (시각화)

- **이미지**: grafana/grafana:latest
- **포트**: 3000
- **데이터소스**: Prometheus, Loki (자동 구성)

**접근**: `https://central.{BASE_DOMAIN}/grafana`

### Loki (로그 집계)

- **이미지**: grafana/loki:latest
- **포트**: 3100

### Promtail (로그 수집)

- **이미지**: grafana/promtail:latest
- **수집 대상**: 모든 Docker 컨테이너 로그

### Maintenance (점검 페이지)

- **이미지**: nginx:alpine
- **용도**: 앱 업그레이드 중 사용자에게 점검 안내

---

## 네트워크 아키텍처

```
[Client]
    │  TLS (Cloudflare 공인 인증서)
    ▼
[Cloudflare Edge]
    │  TLS (Origin Certificate, Full strict)
    │  *.example.com, *.app.example.com → 서버 IP
    ▼
[서버 :443 — Traefik]
    │  Host 헤더 기반 라우팅
    │  [central-net]
    │
    ├── central-maintenance
    ├── central-mysql
    ├── central-grafana
    ├── central-prometheus
    ├── central-loki
    ├── central-promtail
    ├── app-{name}-server
    └── app-{name2}-server ...
```

### 외부 네트워크

모든 서비스는 `central-net` 외부 네트워크에 연결됩니다:

```bash
# 네트워크 생성 (setup 시 자동 생성)
docker network create central-net

# 네트워크 확인
docker network inspect central-net
```

---

## TLS/SSL 설정

### Cloudflare Origin Certificate

1. Cloudflare 대시보드 → SSL/TLS → Origin Server
2. "Create Certificate" 클릭
3. 호스트 이름: `*.example.com`, `*.app.example.com`
4. 유효기간: 15년
5. 생성된 인증서와 키를 저장:
   ```
   central-infra/certs/origin.pem  # 인증서
   central-infra/certs/origin.key  # 개인키
   ```

### SSL/TLS 모드

Cloudflare SSL/TLS 설정에서 **Full (strict)** 모드 사용:

- **Full**: Cloudflare ↔ 서버 간 TLS 암호화
- **Strict**: Origin Certificate 검증 (권장)

---

## 모니터링

### Prometheus 메트릭

**Spring Boot 앱 설정**:

```yaml
# compose.base.yml
services:
  app-server:
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=8080"
```

**앱 dependencies**:
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

### Grafana 대시보드

1. `https://central.{BASE_DOMAIN}/grafana` 접속
2. 기본 계정: admin / {GF_SECURITY_ADMIN_PASSWORD}
3. 데이터소스가 자동으로 구성됨
4. 대시보드 임포트:
   - Node Exporter: ID 1860
   - Spring Boot: ID 12900

### 로그 조회 (Loki)

Grafana → Explore → Loki:
```logql
{container_name="app-myapp-server"}
```

---

## 문제 해결

### Traefik 라우팅 문제

```bash
# Traefik 로그 확인
docker logs central-traefik

# 라우팅 규칙 확인
docker exec central-traefik wget -qO- http://localhost:8080/api/http/routers
```

### 컨테이너 통신 문제

```bash
# 네트워크 연결 확인
docker network inspect central-net

# 컨테이너에서 다른 서비스 ping
docker exec -it app-myapp-server ping central-mysql
```

### SSL 인증서 문제

```bash
# 인증서 파일 확인
ls -la central-infra/certs/

# 인증서 내용 확인
openssl x509 -in central-infra/certs/origin.pem -text -noout
```

### 볼륨 데이터 확인

```bash
# 볼륨 목록
docker volume ls

# 볼륨 내용 확인
docker run --rm -v mysql-data:/data alpine ls -la /data
```

---

## 마이그레이션

### 서버 이전

```bash
# [현재 서버]
./infra archive
# → infra-backup-YYYYMMDD-HHMMSS.tar.gz 생성

# [새 서버]
# 1. Docker 설치
# 2. 아카이브 전송
scp infra-backup-*.tar.gz newserver:~/

# 3. 아카이브 해제
tar -xzf infra-backup-*.tar.gz

# 4. 인프라 시작
./infra setup  # 네트워크 재생성
./infra start  # 모든 서비스 시작
```

### 도메인 변경

```bash
# 1. .env 파일 수정
vim .env
# BASE_DOMAIN=newdomain.io

# 2. Cloudflare DNS 및 인증서 업데이트
# (수동 작업)

# 3. 서비스 재시작
./infra stop
./infra start
```

---

## 참고

- [APP.md](APP.md) - 애플리케이션 개발자 가이드
- [plans/IMPL.md](../plans/IMPL.md) - 구현 계획서
- [plans/PRD.md](../plans/PRD.md) - 요구사항 정의서
