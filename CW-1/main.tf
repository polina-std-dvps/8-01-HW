terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone      = "ru-central1-a"
  folder_id = "b1gukuva87u82hnqbil3"
}

# 1. Используем вашу существующую сеть
data "yandex_vpc_network" "site_net" {
  network_id = "enp05kgo8tr10hq012cn" 
}

# Статические внешние IP: чтобы NAT-адреса не менялись при перезагрузках
# ВАЖНО: квота vpc.externalStaticAddresses.count = 2, обе заняты (одна — ALB).
# TODO: поднять квоту в консоли Yandex Cloud и раскомментировать:
# resource "yandex_vpc_address" "web_a_ip" {
#   name = "static-ip-web-a"
#   external_ipv4_address {
#     zone_id = "ru-central1-e"
#   }
# }
#
# resource "yandex_vpc_address" "monitoring_ip" {
#   name = "static-ip-monitoring"
#   external_ipv4_address {
#     zone_id = "ru-central1-e"
#   }
# }

# Уже существующий адрес 158.160.232.138 (импортирован из облака)
resource "yandex_vpc_address" "web_b_ip" {
  name = "static-ip-web-b"
  external_ipv4_address {
    zone_id = "ru-central1-d"
  }
}

# Подсети
resource "yandex_vpc_subnet" "subnet_a" {
  name           = "subnet-light-c"
  zone           = "ru-central1-e"
  network_id     = data.yandex_vpc_network.site_net.id
  v4_cidr_blocks = ["192.168.110.0/24"]
}

resource "yandex_vpc_subnet" "subnet_b" {
  name           = "subnet-light-d"
  zone           = "ru-central1-d"
  network_id     = data.yandex_vpc_network.site_net.id
  v4_cidr_blocks = ["192.168.120.0/24"]
}

# =============================================================================
# ПУНКТ «СЕТЬ»: SECURITY GROUPS (файрвол по портам сервисов) + BASTION
# =============================================================================

# SG bastion: единственный SSH-вход снаружи (SSH-only ВМ)
resource "yandex_vpc_security_group" "bastion" {
  name       = "sg-bastion"
  network_id = data.yandex_vpc_network.site_net.id

  ingress {
    description    = "SSH из интернета (задание: bastion-ВМ SSH-only)"
    protocol       = "tcp"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "SSH к внутренним ВМ + любые исходящие"
    protocol       = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG мониторинг: Prometheus + Grafana
resource "yandex_vpc_security_group" "monitoring" {
  name       = "sg-monitoring"
  network_id = data.yandex_vpc_network.site_net.id

  ingress {
    description       = "SSH только через bastion"
    protocol          = "tcp"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  ingress {
    description    = "Prometheus UI/API"
    protocol       = "tcp"
    port           = 9090
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Grafana UI"
    protocol       = "tcp"
    port           = 3000
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "scrape exporters, docker pulls и пр."
    protocol       = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG web: nginx-сайты, exporters, ES (filebeat внутри VPC), Kibana
resource "yandex_vpc_security_group" "web" {
  name       = "sg-web"
  network_id = data.yandex_vpc_network.site_net.id

  ingress {
    description    = "HTTP: сайт от ALB"
    protocol       = "tcp"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description       = "SSH только через bastion"
    protocol          = "tcp"
    port              = 22
    security_group_id = yandex_vpc_security_group.bastion.id
  }

  ingress {
    description       = "Порт 9100 — Node Exporter ← Prometheus"
    protocol          = "tcp"
    port              = 9100
    security_group_id = yandex_vpc_security_group.monitoring.id
  }

  ingress {
    description       = "Порт 9113 — nginx-exporter ← Prometheus"
    protocol          = "tcp"
    port              = 9113
    security_group_id = yandex_vpc_security_group.monitoring.id
  }

  ingress {
    description       = "Порт 4040 — nginxlog-exporter (helmich) ← Prometheus"
    protocol          = "tcp"
    port              = 4040
    security_group_id = yandex_vpc_security_group.monitoring.id
  }

  ingress {
    description    = "Порт 9200 — Elasticsearch ← filebeat с web-ВМ (обе приватные подсети)"
    protocol       = "tcp"
    port           = 9200
    v4_cidr_blocks = ["192.168.110.0/24", "192.168.120.0/24"]
  }

  ingress {
    description    = "Порт 5601 — Kibana UI"
    protocol       = "tcp"
    port           = 5601
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "filebeat → ES, apt/docker pulls и пр."
    protocol       = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG ALB: слушает 80/443 снаружи, ходит к целям по 80
resource "yandex_vpc_security_group" "alb" {
  name       = "sg-alb"
  network_id = data.yandex_vpc_network.site_net.id

  ingress {
    description    = "HTTP от пользователей"
    protocol       = "tcp"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "HTTPS от пользователей (запас)"
    protocol       = "tcp"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description       = "Трафик к целевым ВМ (backend suite:80)"
    protocol          = "tcp"
    port              = 80
    security_group_id = yandex_vpc_security_group.web.id
  }
}

# Bastion-ВМ: SSH-only вход во все частные ВМ (Пункт «Сеть»)
resource "yandex_compute_instance" "bastion" {
  name        = "bastion"
  platform_id = "standard-v3"
  zone        = "ru-central1-d"

  lifecycle {
    prevent_destroy = true
  }

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 8
      type     = "network-ssd" # квота SSD в зоне d свободна
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.subnet_b.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.bastion.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

# 2. Виртуальные машины на базовой платформе standard-v1 (с ограничением vCPU 20%)
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

resource "yandex_compute_instance" "web_a" {
  name        = "web-server-a"
  platform_id = "standard-v3"
  zone        = "ru-central1-e"

  # Защита: TF отклонит план, где ВМ разрушается (учиться на ошибке 26.10.2026)
  lifecycle {
    prevent_destroy = true
  }

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20 # Гарантирует прохождение по лимитам триал-аккаунта
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 15
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_a.id
    nat       = true
    security_group_ids = [yandex_vpc_security_group.web.id]
    # static-ip-web-a — после поднятия квоты:
    # nat_ip_address = yandex_vpc_address.web_a_ip.external_ipv4_address[0].address
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "yandex_compute_instance" "web_b" {
  name        = "web-server-b"
  platform_id = "standard-v3"
  zone        = "ru-central1-d"

  # Защита: TF отклонит план, где ВМ разрушается (учиться на ошибке 26.10.2026)
  lifecycle {
    prevent_destroy = true
  }

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 15
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_b.id
    nat       = true
    security_group_ids = [yandex_vpc_security_group.web.id]
    nat_ip_address = yandex_vpc_address.web_b_ip.external_ipv4_address[0].address
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

# 3. Целевая группа и NLB удалены: по заданию сайт отдаёт Application Load
# Balancer (выше в файле), fallback-балансировщик был временной страховкой.

# Вывод IP-адресов для Ansible и проверки
output "web_server_a_public_ip" {
  value = yandex_compute_instance.web_a.network_interface.0.nat_ip_address
}

output "web_server_a_private_ip" {
  value = yandex_compute_instance.web_a.network_interface.0.ip_address
}

output "web_server_b_private_ip" {
  value = yandex_compute_instance.web_b.network_interface.0.ip_address
}

output "web_server_b_public_ip" {
  value = yandex_compute_instance.web_b.network_interface.0.nat_ip_address
}

# =============================================================================
# РЕЗЕРВНОЕ КОПИРОВАНИЕ: ежедневные снапшоты всех boot-дисков, TTL 7 дней
# =============================================================================
resource "yandex_compute_snapshot_schedule" "daily" {
  name = "cw1-daily-snapshots"

  schedule_policy {
    expression = "0 2 * * *" # cron: ежедневно в 02:00 UTC
  }

  retention_period = "168h0m0s" # 7 дней

  disk_ids = [
    yandex_compute_instance.web_a.boot_disk.0.disk_id,
    yandex_compute_instance.web_b.boot_disk.0.disk_id,
    yandex_compute_instance.prometheus.boot_disk.0.disk_id,
  ]
}

# =============================================================================
# МОНИТОРИНГ: ВИРТУАЛЬНЫЕ МАШИНЫ
# =============================================================================# =============================================================================
# APPLICATION LOAD BALANCER (по заданию: Target Group -> Backend Group -> HTTP Router -> ALB)
# =============================================================================

# 1. Target Group для ALB (внутренние IP веб-серверов)
resource "yandex_alb_target_group" "alb_tg" {
  name = "alb-tg-web"

  target {
    subnet_id  = yandex_vpc_subnet.subnet_a.id
    ip_address = yandex_compute_instance.web_a.network_interface.0.ip_address
  }

  target {
    subnet_id  = yandex_vpc_subnet.subnet_b.id
    ip_address = yandex_compute_instance.web_b.network_interface.0.ip_address
  }
}

# 2. Backend Group: бэкенд на порт 80, healthcheck на корень (/), протокол HTTP
resource "yandex_alb_backend_group" "alb_backend" {
  name = "alb-backend-web"

  http_backend {
    name             = "main-backend"
    weight           = 1
    port             = 80
    target_group_ids = [yandex_alb_target_group.alb_tg.id]

    healthcheck {
      timeout             = "1s"
      interval            = "2s"
      healthy_threshold   = 2
      unhealthy_threshold = 2
      http_healthcheck {
        path = "/"
      }
    }
  }
}

# 3. HTTP Router + виртуальный хост (в этом провайдере vhost — отдельный ресурс)
resource "yandex_alb_http_router" "alb_router" {
  name = "alb-router-web"
}

resource "yandex_alb_virtual_host" "alb_vhost" {
  name           = "web-vhost"
  http_router_id = yandex_alb_http_router.alb_router.id

  route {
    name = "web-route"

    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.alb_backend.id
        timeout          = "10s"
        idle_timeout     = "60s"
      }
    }
  }
}

# 4. Application Load Balancer: listener port 80 -> HTTP Router
resource "yandex_alb_load_balancer" "web_alb" {
  name               = "web-app-lb"
  network_id         = data.yandex_vpc_network.site_net.id
  security_group_ids = [yandex_vpc_security_group.alb.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-e"
      subnet_id = yandex_vpc_subnet.subnet_a.id
    }

    location {
      zone_id   = "ru-central1-d"
      subnet_id = yandex_vpc_subnet.subnet_b.id
    }
  }

  listener {
    name = "external-http"

    endpoint {
      address {
        external_ipv4_address {}
      }
      ports = [80]
    }

    http {
      handler {
        http_router_id = yandex_alb_http_router.alb_router.id
      }
    }
  }
}

# ВМ для Prometheus (в приватной подсети зоны A)
resource "yandex_compute_instance" "prometheus" {
  name        = "monitoring-prometheus"
  platform_id = "standard-v3"
  zone        = "ru-central1-e"

  # Защита: TF отклонит план, где ВМ разрушается (учиться на ошибке 26.10.2026)
  lifecycle {
    prevent_destroy = true
  }

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10
      type     = "network-ssd"     # Переключили на SSD, чтобы обойти лимит HDD
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet_a.id
    nat       = true # ПРИВАТНАЯ СЕТЬ: нет прямого доступа из интернета, временно да для ансибла
    security_group_ids = [yandex_vpc_security_group.monitoring.id]
    # static-ip-monitoring — после поднятия квоты:
    # nat_ip_address = yandex_vpc_address.monitoring_ip.external_ipv4_address[0].address
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}


# =============================================================================
# ДОПОЛНИТЕЛЬНЫЕ ВЫВОДЫ (OUTPUTS)
# =============================================================================

output "prometheus_public_ip" {
  value = yandex_compute_instance.prometheus.network_interface.0.nat_ip_address
}

output "bastion_public_ip" {
  value = yandex_compute_instance.bastion.network_interface.0.nat_ip_address
}

