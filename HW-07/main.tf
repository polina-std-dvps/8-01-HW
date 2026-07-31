terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      version = ">= 0.100.0"
    }
  }
}

variable "folder_id" {
  description = "ID каталога"
}
variable "subnet_id" {
  description = "ID подсети"
}
variable "service_account_id" {
  description = "ID сервисного аккаунта"
}
variable "yandex_token" {
  description = "IAM-токен"
}
variable "sa_key_file" {
  description = "/home/Polina/net.hw/authorized_key.json"
}
provider "yandex" {
  folder_id = var.folder_id
  #token     = var.yandex_token
  service_account_key_file = var.sa_key_file
  zone = "ru-central1-b"
}

#Сеть
resource "yandex_vpc_network" "network1" {
  name = "network1"
}

#Подсеть
resource "yandex_vpc_subnet" "subnet1" {
  name          = "subnet1"
  network_id    = yandex_vpc_network.network1.id
  v4_cidr_blocks = ["10.0.0.0/24"]
}

# Виртуальные машины
resource "yandex_compute_instance" "vm" {
  count = 2

  name        = "vm-${count.index}"
  platform_id = "standard-v1"

  boot_disk {
    initialize_params {
      image_id = "fd83ica41cade1mj35sr"  # ubuntu 24.04
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet1.id
    nat       = true
  }

  resources {
    cores  = 2
    memory = 2
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_ed25519_nopass.pub")}"
  }
}

# Целевая группа (Target Group) с динамическим наполнением из count
resource "yandex_alb_target_group" "web_tg" {
  name = "web-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.vm
    content {
      subnet_id  = yandex_vpc_subnet.subnet1.id
      ip_address = target.value.network_interface.0.ip_address
    }
  }
}

# Группа бэкендов (Backend Group)
resource "yandex_alb_backend_group" "web_bg" {
  name = "web-backend-group"

  http_backend {
    name             = "main-backend"
    port             = 80
    target_group_ids = [yandex_alb_target_group.web_tg.id]

    healthcheck {
      interval            = "2s"
      timeout             = "1s"
      unhealthy_threshold = 2
      healthy_threshold   = 2

      http_healthcheck {
        path = "/"
      }
    }

    load_balancing_config {
      panic_threshold = 1
    }
  }
}

# HTTP Роутер (контейнер для виртуальных хостов)
resource "yandex_alb_http_router" "web_router" {
  name = "web-router"
}

# Виртуальный хост
resource "yandex_alb_virtual_host" "web_vhost" {
  name           = "web-vhost"
  http_router_id = yandex_alb_http_router.web_router.id

  route {
    name = "web-route"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.web_bg.id
        timeout          = "10s"
        idle_timeout     = "60s"
      }
    }
  }
}

# Балансировщик (Application Load Balancer)
resource "yandex_alb_load_balancer" "web_lb" {
  name       = "web-load-balancer"
  network_id = yandex_vpc_network.network1.id

  allocation_policy {
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.subnet1.id
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
        http_router_id = yandex_alb_http_router.web_router.id
      }
    }
  }
}
