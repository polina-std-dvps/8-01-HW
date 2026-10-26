# Контрольная работа — Terraform + Ansible (Яндекс.Облако)

**Автор:** Жихарева Полина
**Папка:** `CW-1/`

## Архитектура

- **ВМ web-server-a** (ru-central1-e) — nginx, Node Exporter, Nginx Log Exporter
- **ВМ web-server-b** (ru-central1-d) — nginx, Node Exporter, Nginx Log Exporter, статический внешний IP
- **ВМ monitoring** (ru-central1-e) — Prometheus (Grafana поставим на отдельную ВМ)
- Network Load Balancer → Target Group из 2 web-серверов (healthcheck `/:80`)

Инфраструктура описана через Terraform (`main.tf`), настройка сервисов — через Ansible:
`deploy.yml` (nginx+сайт), `monitoring.yml` (экспортеры+Prometheus), `logging.yml` (Filebeat).

## 1. Инфраструктура и сайт — ✅

- Создание ВМ через Terraform (Terraform output: IP всех машин, статический у web-b):

![Terraform output](terraform_output.png)

- ВМ в разных зонах (ru-central1-e и ru-central1-d), но с идентичной настройкой через один плейбук:

![Yandex Cloud: инстансы и зоны](yc_comp_zone.png)

- Установка nginx и деплой статического сайта:

![Ansible deploy](ansible_playbook.png)

- Проверка сайта через балансировщик:

![curl -v через балансировщик](curl.png)

### ALB-цепочка (по заданию) — ✅

Цепочка целиком в Terraform (`main.tf`):
`yandex_alb_target_group` (обе ВМ по внутренним IP) → `yandex_alb_backend_group`
(backend `:80`, healthcheck `GET /`) → `yandex_alb_http_router` → `yandex_alb_virtual_host`
→ `yandex_alb_load_balancer` (listener `:80`, type auto, 2 зоны).

- Проверка через Application Load Balancer (`51.250.9.248`):

![curl через ALB](alb_curl.png)

## 2. Мониторинг — ✅ (одна деталь до завершения)

Node Exporter + nginx-exporter (stub_status на 127.0.0.1:8080) на обеих web; Prometheus (`:9090`)
собирает 4 таргета (внутренние IP, конфиг генерируется из inventory).

Grafana — `:3000` на monitoring-ВМ, в docker; datasource и дашборд
(`dashboards/cw-utilization.json`) провижинятся Ansible'ом автоматически
(панели: CPU/RAM/диски/сеть — Utilization/Saturation/Errors + `http_response_count_total`,
`http_response_size_bytes`, thresholds прописаны).

> TODO: по заданию нужен **Nginx Log Exporter** (helmich) для метрик `http_response_*` —
> добавим в `monitoring.yml`, после чего панели 9-10 дашборда оживут.

![Grafana](grafana_dashboards.png)

## 3. Логи — ✅

**Распределение по ВМ (docker из-за дисковых квот Я.Клауд — отдельные ВМ под ES/Grafana
не выделяются, но каждый сервис при этом на своей ВМ):**

- **web-a**: nginx + Elasticsearch 7.17.10 (docker, heap 512M) — `:9200` внутри VPC
- **web-b**: nginx + Kibana 7.17.10 (docker) — `:5601`
- Filebeat: docker на обеих web (логи nginx монтируются внутрь read-only)

Конфиг filebeat генерирует `logging.yml`, ES-host берётся из `inventory.ini`.

Итог: логи access.log/error.log попадают в ES (индекс `filebeat-7.17.10-*`),
Kibana показывает их в UI.

- Kibana с логами (index pattern `filebeat-*`):

![Kibana](kibana_logs.png)

- Проверка ES кластера (green, 9k+ документов):

![ES](es_health.png)

## 4. Сеть — 🚧 TODO

Единый VPC (`default`), подсети zone e (192.168.110/24) и zone d (192.168.120/24), ALB публичный.
TODO: Security Groups по портам сервисов + bastion-ВМ (SSH-only) — кнопка в конце сдачи.

## 5. Резервное копирование — ✅

Snapshot schedule `cw1-daily-snapshots` (Terraform, `fd8ilnfe5f94tutifka1`):
cron `0 2 * * *` (ежедневно 02:00 UTC), retention 168h (7 дней),
все три boot-диска (web-a, web-b, monitoring).

![Snapshot schedule](snapshot_schedule.png)
