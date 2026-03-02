# 단일 서버 토이 프로젝트 인프라 구현 계획서

**버전 4.0 | 2026-03-02**

***

## 1. 목표 및 운영 철학

본 인프라는 다음 원칙 아래 설계된다.

- **단순성 우선**: 가용성·이중화를 의도적으로 포기하고, 단일 머신에서 최소 구성으로 다수의 토이 프로젝트를 운영한다
- **벤더 독립성**: 클라우드 제공자에 종속되지 않으며, Docker Compose 파일 조합만으로 어떤 머신에서도 동일하게 재현 가능하다
- **인프라의 앱 포용**: 애플리케이션이 인프라를 이해하는 것이 아니라, 인프라가 애플리케이션을 감싼다
- **단방향 의존성**: 하위 인프라(서버)는 상위 인프라(Cloudflare)를 건드리지 않는다
- **관심사 분리**: CI/CD는 앱 이름만 알고, 내부 파일 구조는 서버 스크립트만 안다
- **도메인 투명성**: 어떤 앱 파일도 자신이 서빙되는 도메인을 하드코딩하지 않는다

***

## 2. 전체 아키텍처 개요

### 2-1. 트래픽 흐름

```
[Client]
   │  TLS (Cloudflare 공인 인증서)
   ▼
[Cloudflare Edge]
   │  TLS (Origin Certificate, Full strict)
   │  *.example.com, *.app.example.com → 서버 퍼블릭 IP (Proxied 🟠)
   ▼
[서버 :443 — Traefik]
   │  Host 헤더 기반 내부 라우팅
   │  [central-net] Docker 외부 공유 네트워크
   │
   ├── central-maintenance  (점검 페이지, 항상 기동)
   ├── central-mysql
   ├── central-grafana
   ├── central-prometheus
   ├── central-loki
   ├── central-promtail
   ├── app-{name}-server
   └── app-{name2}-server ...
```

### 2-2. 설정 조합 구조

어떤 단일 파일도 전체 그림을 알지 못한다. 각 레이어가 아는 것은 다음과 같으며, 런타임에 조합될 때만 완전한 라우팅 규칙이 완성된다.

```
~/infra/.env          → BASE_DOMAIN=example.com        (도메인의 유일한 출처)
apps/myapp/.env       → APP_NAME=myapp, APP_PORT=8080  (앱 고유 식별자)
compose.attach.yml    → ${APP_NAME}.app.${BASE_DOMAIN} (변수 참조만, 값 모름)
app-attach-base.yml   → Traefik 공통 라벨 구조         (앱 이름·도메인 모름)
compose.base.yml      → 이미지, 환경변수               (라우팅 전혀 모름)
```

| 레이어 | 아는 것 | 모르는 것 |
|---|---|---|
| `compose.base.yml` | 이미지, 앱 환경변수 | 도메인, 라우팅 |
| `apps/myapp/.env` | `APP_NAME`, `APP_PORT` | `BASE_DOMAIN` |
| `compose.attach.yml` | `APP_NAME`, `APP_PORT` (변수 참조) | `BASE_DOMAIN` |
| `app-attach-base.yml` | Traefik 공통 라벨 구조 | 도메인, 앱 이름 |
| `~/infra/.env` | `BASE_DOMAIN` | 앱 이름, 포트 |

### 2-3. CI/CD 흐름

```
[개발자: git push → main]
   │
   ▼
[GitHub Actions]
   ├── Job 1 — 자동 실행
   │     docker build
   │     ghcr.io/org/appname:latest
   │     ghcr.io/org/appname:{sha}   ← 롤백용
   │
   └── Job 2 — 수동 승인 대기 (GitHub Environment: production)
         Reviewer 승인 후
         → SSH: ./app upgrade {appname}
```

### 2-4. 업그레이드 시 라우팅 전환 흐름

```
./app upgrade myapp
   │
   ├─ 1. traefik/dynamic/maintenance-myapp.yml 생성
   │       Traefik 파일 프로바이더 즉시 감지
   │       → myapp.app.example.com → central-maintenance (점검 페이지)
   │       (DNS 변경 아님 → DNS 캐시 우려 없음)
   │
   ├─ 2. docker compose pull + up -d --no-deps
   │       구 컨테이너 종료 → 신 컨테이너 기동
   │       점검 페이지 계속 서빙
   │
   └─ 3. maintenance-myapp.yml 삭제
           Traefik 즉시 감지
           → myapp.app.example.com → app-myapp-server 복구
```

***

## 3. 기술적 의사결정

### 3-1. 리버스 프록시: Traefik

**결정**: Traefik 채택

이 요구사항의 핵심인 **"앱 추가/제거 시 중앙 인프라 무중단"** 을 네이티브로 충족하는 유일한 선택지다. Docker 소켓을 실시간 감시하며 컨테이너 라벨만으로 라우팅 규칙을 즉각 반영한다. 파일 프로바이더를 병행해 스크립트가 `dynamic/` 디렉터리에 파일을 생성·삭제하는 것만으로 점검 페이지 전환이 가능하다.

| 후보 | 미채택 이유 |
|---|---|
| Nginx | 서비스 추가마다 `nginx.conf` 수동 수정 + reload 필요. 자동화 시 `docker-gen` 컴패니언 툴 추가 필요 |
| HAProxy | Docker 동적 감지 미지원. TLS 자동화 추가 구성 필요. 10 RPS 수준에서 성능 이점 없음 |
| Caddy | 서비스 추가마다 Caddyfile 수동 수정 필요. 파일 프로바이더 방식 점검 페이지 전환 미지원 |

### 3-2. TLS: Cloudflare Origin Certificate + Full (strict)

**결정**: Cloudflare Origin Certificate 채택

TLS 연결은 두 구간으로 구성된다.

```
Client ─── TLS(Cloudflare 공인 인증서) ─── Cloudflare Edge ─── TLS(Origin 인증서) ─── Traefik
```

- **Client ↔ Cloudflare**: Cloudflare 공인 인증서, 브라우저 신뢰
- **Cloudflare ↔ 서버**: Origin Certificate (Cloudflare 서명, 최대 15년 유효)
- Cloudflare SSL/TLS 모드를 반드시 **Full (strict)** 으로 설정해 Cloudflare ↔ 서버 구간 평문 전송을 방지한다

Origin Certificate는 Cloudflare 대시보드에서 수동 발급(`*.example.com`, `*.app.example.com` 와일드카드 포함) 후 서버에 파일로 배치한다. 이후 서버는 Cloudflare에 어떤 API 요청도 보내지 않는다.

| 후보 | 미채택 이유 |
|---|---|
| DNS-01 Challenge + Cloudflare API | 서버가 Cloudflare에 쓰기 권한을 가지는 단방향 의존성 위반. 서버 침해 시 DNS 전체 위험 노출 |
| Let's Encrypt HTTP-01 | 와일드카드 인증서 발급 불가. Cloudflare 프록시 비활성화로 DDoS 방어·IP 은닉 포기 |

### 3-3. 공유 네트워크: Docker 외부 네트워크

`central-net`이라는 단일 외부 네트워크를 미리 생성하고, 모든 Compose 프로젝트가 `external: true`로 참조한다. 같은 네트워크 소속 컨테이너끼리는 `container_name`을 DNS처럼 사용해 상호 통신할 수 있다. 앱의 기동·종료가 중앙 인프라와 다른 앱에 영향을 주지 않는다.

### 3-4. 공통 설정 중앙화: `extends` 기반 Fragment

Compose의 `extends` 키워드로 인프라 공통 설정을 `central-infra/fragments/app-attach-base.yml` 단일 파일에서 관리한다. `extends`는 런타임에 파일 경로를 참조하므로, Traefik 라벨 구조가 변경될 때 fragment 파일 하나만 수정하면 모든 앱에 즉시 반영된다. YAML anchor는 파일 간 공유가 불가능해 이 용도에 적합하지 않다.

### 3-5. 도메인 투명성: `BASE_DOMAIN` 환경변수 분리

앱 파일이 도메인을 하드코딩하지 않도록 도메인 정보를 인프라 전역 `.env`에서만 관리한다. 스크립트가 compose 실행 시 두 `.env`를 순서대로 주입한다.

```bash
docker compose \
  --env-file ~/infra/.env \       # BASE_DOMAIN (인프라 전역)
  --env-file ./apps/myapp/.env \  # APP_NAME, APP_PORT (앱 고유)
  -f compose.base.yml \
  -f compose.attach.yml \
  up -d
```

도메인이 바뀌어도 `~/infra/.env` 한 줄만 수정하면 된다. 앱 파일은 단 한 줄도 수정하지 않는다.

### 3-6. 모니터링: Prometheus + Grafana + Loki + Promtail

| 역할 | 도구 | 수집 대상 |
|---|---|---|
| 메트릭 수집 | Prometheus | Spring Actuator, MySQL Exporter, Node Exporter |
| 호스트 메트릭 | Node Exporter | CPU / 메모리 / 디스크 |
| 로그 집계 | Loki + Promtail | 전체 컨테이너 로그 (`docker.sock` 마운트) |
| 시각화 | Grafana | Prometheus + Loki 데이터소스 |

Promtail은 `docker.sock`을 통해 `central-net`에 연결된 모든 컨테이너 로그를 앱 측 설정 없이 자동 수집한다.

### 3-7. 이미지 관리: GitHub Actions → GHCR

빌드는 GitHub Actions에서 수행하고 결과 이미지를 GHCR에 push한다. 서버는 pull만 수행한다. GHCR은 `GITHUB_TOKEN`으로 별도 인증 설정 없이 사용 가능하다. 롤백을 위해 `latest` 태그 외에 커밋 SHA 태그를 병행 push한다.

### 3-8. 배포 안전성: GitHub Environment 수동 승인

배포 job은 GitHub Environment `production`으로 선언해, 지정 Reviewer 수동 승인 후에만 SSH 접속 및 컨테이너 교체가 실행된다. CI/CD가 서버에 전달하는 명령은 `./app upgrade {name}` 한 줄뿐이며, 내부 파일 구조는 서버 스크립트만 안다.

***

## 4. DNS 구성

Cloudflare 대시보드에서 아래 레코드를 설정한다. **서버는 이 레코드를 건드리지 않는다.**

```
타입    이름       값                   프록시 상태
────────────────────────────────────────────────
A       @          {서버 퍼블릭 IP}     Proxied (🟠)
A       central    {서버 퍼블릭 IP}     Proxied (🟠)
CNAME   *.app      example.com          Proxied (🟠)
```

`*.app` 와일드카드 레코드 덕분에 앱이 추가되어도 DNS 레코드 변경이 불필요하다.

***

## 5. 네트워크 식별자 규칙

| 구분 | 인트라넷 (`container_name`) | 인터넷 (Traefik 라우팅) |
|---|---|---|
| 중앙 인프라 | `central-mysql`, `central-grafana` 등 | `central.${BASE_DOMAIN}/{허용 경로}` |
| 점검 페이지 | `central-maintenance` | 업그레이드 시에만 노출, 직접 접근 불가 |
| 각 앱 | `app-{name}-server` 등 | `{name}.app.${BASE_DOMAIN}` |

***

## 6. 디렉터리 구조

```
~/infra/
├── .env                               # ★ BASE_DOMAIN (도메인의 유일한 출처)
│
├── central-infra/
│   ├── compose.yml                    # Traefik, MySQL, Grafana, Prometheus, Loki, Maintenance
│   ├── traefik/
│   │   ├── traefik.yml                # static config (entrypoints, provider 설정)
│   │   └── dynamic/                   # ★ 파일 프로바이더 감시 디렉터리 (watch: true)
│   │       └── (평시 비어 있음)
│   │           maintenance-{name}.yml # upgrade 스크립트가 생성/삭제
│   ├── certs/
│   │   ├── origin.pem                 # Cloudflare Origin Certificate (수동 배치)
│   │   └── origin.key
│   ├── prometheus/
│   │   └── prometheus.yml             # scrape targets
│   ├── maintenance/
│   │   ├── index.html                 # 기본 점검 안내 페이지
│   │   └── {name}/
│   │       └── index.html             # 앱별 커스텀 점검 페이지 (선택)
│   └── fragments/
│       └── app-attach-base.yml        # ★ 공통 인프라 설정의 단일 진실 공급원(SSOT)
│
├── apps/
│   ├── myapp/
│   │   ├── .env                       # APP_NAME=myapp, APP_PORT=8080
│   │   ├── compose.base.yml           # 앱 정의 (이미지, 환경변수) — 개발자 작성
│   │   └── compose.attach.yml         # 인프라 연결 (extends + 변수 참조) — 스크립트 생성
│   └── otherapp/
│       ├── .env
│       ├── compose.base.yml
│       └── compose.attach.yml
│
├── infra                              # 중앙 인프라 관리 CLI
└── app                                # 앱 관리 CLI
```

***

## 7. 운영 CLI 인터페이스

### 7-1. `./infra` — 중앙 인프라 관리

```bash
./infra setup      # 최초 환경 구성 — 멱등적 실행 보장
                   # docker network create central-net (존재 시 skip)
                   # 디렉터리 구조 생성, .env 템플릿 생성
                   # 전제조건 체크: Docker 설치, 포트 80/443 사용 가능 여부

./infra start      # 중앙 인프라 기동 → apps/ 하위 전체 앱 순서대로 기동
./infra stop       # 앱 역순 종료 → 중앙 인프라 종료 (볼륨 삭제 없음)
./infra status     # 모든 컨테이너 상태 일람 출력
./infra archive    # 마이그레이션용 아카이브 생성
                   # 확인 프롬프트 → ./infra stop → tar → 파일 경로 및 크기 안내
```

### 7-2. `./app` — 앱 관리

```bash
./app create <name> <port> # scaffold
                           # 이름 유효성 검사 (영소문자·하이픈), 중복 체크
                           # apps/<name>/.env 생성 (APP_NAME, APP_PORT)
                           # compose.attach.yml 생성 (fragment extends + 변수 참조)
                           # compose.base.yml 템플릿 생성 + 다음 단계 안내

./app remove <name>        # 확인 프롬프트 → docker compose down → 파일 정리
./app start <name>         # 해당 앱 기동 (포트는 .env에서 읽음, 인자 불필요)
./app stop <name>          # 해당 앱 종료
./app upgrade <name>       # 점검 전환 → 업그레이드 → 라우팅 복구 (아래 상세)
./app list                 # 등록된 앱 목록 및 컨테이너 상태
```

**`./app start`에 포트 번호가 불필요한 이유**: 포트는 `./app create` 실행 시 `apps/<name>/.env`에 `APP_PORT`로 기록된다. 이후 모든 명령은 이 파일을 읽으므로 포트를 다시 인자로 받을 필요가 없다.

### 7-3. `./app upgrade` 상세 동작

```bash
upgrade() {
  APP_NAME=$1
  APP_DIR="$APPS_DIR/$APP_NAME"
  MAINTENANCE_FILE="$CENTRAL_INFRA_DIR/traefik/dynamic/maintenance-${APP_NAME}.yml"
  COMPOSE_ARGS="--env-file $INFRA_ROOT/.env --env-file $APP_DIR/.env
                -f $APP_DIR/compose.base.yml -f $APP_DIR/compose.attach.yml"

  # 1. 점검 페이지 전환
  generate_maintenance_yaml "$APP_NAME" > "$MAINTENANCE_FILE"
  sleep 1   # Traefik 파일 프로바이더 감지 대기

  # 2. 업그레이드 (set -e: 실패 시 즉시 중단, finally에서 파일 삭제 보장)
  trap "rm -f $MAINTENANCE_FILE" EXIT
  docker compose $COMPOSE_ARGS pull
  docker compose $COMPOSE_ARGS up -d --no-deps "app-${APP_NAME}-server"

  # 3. 라우팅 복구 (trap에 의해 보장)
}
```

`trap ... EXIT`를 사용해 업그레이드 중 오류가 발생하더라도 점검 페이지 파일이 반드시 삭제된다.

### 7-4. CLI 설계 불변 원칙

- `./app create/remove`는 `central-infra/compose.yml`을 **절대 수정하지 않음**
- `./infra stop/archive`는 볼륨 데이터를 **절대 삭제하지 않음**
- 파괴적 작업(`remove`, `archive`)은 **명시적 확인 프롬프트** 필수
- 모든 스크립트는 `set -e`로 오류 발생 시 즉시 중단
- 모든 compose 실행은 `--env-file ~/infra/.env`와 앱별 `.env`를 **항상 명시적으로 전달**

***

## 8. 앱 수명주기 상세 흐름

### 앱 추가

```
1. ./app create myapp 8080
     → apps/myapp/.env 생성: APP_NAME=myapp, APP_PORT=8080
     → compose.attach.yml 생성 (변수 참조, 도메인 하드코딩 없음)
     → compose.base.yml 템플릿 생성

2. 개발자: compose.base.yml에 이미지·환경변수 작성

3. ./app start myapp
     → docker compose (--env-file 두 개 주입) up -d
     → Traefik 즉시 감지
     → myapp.app.example.com 라우팅 활성화
     → 중앙 인프라 및 다른 앱 무중단
```

### 앱 제거

```
./app remove myapp
  → "myapp을 제거합니다. 계속하시겠습니까?" 확인
  → docker compose down (Traefik 즉시 감지 → 라우팅 비활성화)
  → 중앙 인프라 및 다른 앱 무중단
```

### 정기 배포

```
git push (main)
  → Job 1 (자동): build → ghcr.io/org/myapp:latest + :{sha}
  → Job 2 (승인): SSH → ./app upgrade myapp
      점검 전환 → pull + up --no-deps → 라우팅 복구
```

### 롤백

```
apps/myapp/compose.base.yml 이미지 태그를 :{이전sha}로 수정
./app upgrade myapp   ← 점검 전환·롤백 이미지 교체·복구 동일 절차
```

### 도메인 전체 이전

```
~/infra/.env: BASE_DOMAIN=newdomain.io 로 수정
./infra stop && ./infra start
→ 앱 파일 단 한 줄도 수정하지 않음
→ Cloudflare DNS 레코드 및 Origin Certificate 교체는 상위 인프라의 몫
```

***

## 9. 마이그레이션 절차

```bash
# [현재 서버]
./infra archive
# 확인 프롬프트
# ./infra stop 호출
# tar -czf infra-backup-YYYYMMDD-HHMMSS.tar.gz \
#   ~/infra /var/lib/docker/volumes/
# 파일 경로 및 크기 안내

# [새 서버] Docker 설치 후
scp infra-backup-*.tar.gz newserver:~/
tar -xzf infra-backup-*.tar.gz
./infra setup    # central-net 재생성, 전제조건 체크 (멱등적)
./infra start    # 중앙 인프라 + 전체 앱 일괄 기동
```

앱 디렉터리(compose 파일, `.env`)와 Named Volume(MySQL 데이터, Grafana 대시보드, Prometheus TSDB 등)이 보존되므로, 마이그레이션 후 추가 등록 작업 없이 이전 상태가 그대로 복원된다. Origin Certificate 파일(`certs/`)도 `~/infra` 하위에 있어 아카이브에 포함된다.

***

## 10. 성공 기준 매핑

| 요구사항 | 충족 방법 |
|---|---|
| 단일 머신에서 중앙 인프라 + N개 앱 동시 기동 | Docker 외부 네트워크 공유 |
| 앱 추가/제거 시 중앙 인프라 무중단 | Traefik Docker 프로바이더 동적 감지 |
| 공통 인프라 설정 일괄 변경 | `extends` → `app-attach-base.yml` SSOT |
| HTTPS 와일드카드 (앱 추가 시 DNS 작업 없음) | Cloudflare Origin Cert + `*.app` CNAME |
| 서버 → Cloudflare 의존성 없음 | Origin Certificate 수동 배치 (API 미사용) |
| 업그레이드 중 사용자 경험 보장 | `./app upgrade` 점검 페이지 자동 전환/복구 |
| 업그레이드 실패 시 점검 페이지 고착 방지 | `trap EXIT`로 파일 삭제 보장 |
| 앱이 자신의 도메인을 모름 | `BASE_DOMAIN` 전역 `.env` 분리, 변수 참조만 |
| 도메인 이전 시 앱 파일 수정 불필요 | `~/infra/.env` 한 줄 수정으로 전파 |
| 배포 안전성 | GitHub Actions Environment 수동 승인 게이트 |
| CI/CD의 인프라 내부 구조 비노출 | `./app upgrade <name>` 단일 진입점 |
| 메트릭/로그 모니터링 | Prometheus + Grafana + Loki + Promtail |
| 벤더 락인 없이 이관 | `./infra archive` → 새 서버 `./infra start` |

## 11. 문서화

프로젝트 종료 시 [APP.md](../docs/APP.md), [INFRA.md](../docs/INFRA.md) 작성이 필요하다.