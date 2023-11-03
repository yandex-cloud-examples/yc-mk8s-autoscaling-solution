### VPC
resource "yandex_vpc_network" "this" {
  name        = var.network_name
  description = var.network_description

  labels = var.labels
}
resource "yandex_vpc_subnet" "this" {
  for_each       = { for v in var.subnets : v.zone => v }
  name           = "${var.network_name}-${each.value.zone}"
  description    = "${var.network_name} subnet for zone ${each.value.zone}"
  v4_cidr_blocks = each.value.v4_cidr_blocks
  zone           = each.value.zone
  network_id     = yandex_vpc_network.this.id
  labels         = var.labels

  depends_on = [
    yandex_vpc_network.this
  ]
}
### KMS
resource "yandex_kms_symmetric_key" "key" {
  name              = "k8s-symetric-key"
  description       = "description for key"
  default_algorithm = "AES_128"
  rotation_period   = "8760h" // equal to 1 year
}
### Datasource
data "yandex_client_config" "client" {}

resource "random_string" "random" {
  length    = 4
  lower     = true
  special   = false
  min_lower = 4
}

### K8S
# SA
resource "yandex_iam_service_account" "k8s_master_sa" {
  name        = "sa-k8s-master-${random_string.random.result}"
  description = "service account to manage k8s masters"
}

resource "yandex_resourcemanager_folder_iam_member" "service_account_master" {
  folder_id = data.yandex_client_config.client.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.k8s_master_sa.id}"
  role      = "k8s.clusters.agent"
}
resource "yandex_resourcemanager_folder_iam_member" "service_account_master_2" {
  folder_id = data.yandex_client_config.client.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.k8s_master_sa.id}"
  role      = "load-balancer.admin"
}

resource "yandex_resourcemanager_folder_iam_member" "service_account_master_3" {
  folder_id = data.yandex_client_config.client.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.k8s_master_sa.id}"
  role      = "kms.keys.encrypterDecrypter"
}

resource "yandex_iam_service_account" "k8s_node_sa" {
  name        = "sa-k8s-nodes-${random_string.random.result}"
  description = "service account to manage k8s nodes"
}

resource "yandex_resourcemanager_folder_iam_member" "service_account_node" {
  folder_id = data.yandex_client_config.client.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.k8s_node_sa.id}"
  role      = "container-registry.images.puller"
}
resource "null_resource" "iam_sleep" {
  provisioner "local-exec" {
    command = "sleep 5"
  }
}
# Master
resource "yandex_kubernetes_cluster" "regional_cluster" {
  name        = "demo"
  description = "Demonstration of autoscaling"

  network_id = yandex_vpc_network.this.id
  network_implementation {
    cilium {}
  }


  master {
    regional {
      region = "ru-central1"

      dynamic "location" {
        for_each = yandex_vpc_subnet.this
        content {
          zone      = location.value.zone
          subnet_id = location.value.id
        }
      }
    }
    version            = "1.20"
    public_ip          = true
    security_group_ids = [yandex_vpc_security_group.sg_k8s.id, yandex_vpc_security_group.k8s_master_whitelist.id, ]

    maintenance_policy {
      auto_upgrade = true

      maintenance_window {
        day        = "monday"
        start_time = "15:00"
        duration   = "3h"
      }

      maintenance_window {
        day        = "friday"
        start_time = "10:00"
        duration   = "4h30m"
      }
    }
  }
  service_ipv4_range = var.k8s_service_ipv4_range
  cluster_ipv4_range = var.k8s_pod_ipv4_range
  release_channel    = "RAPID"
  #network_policy_provider = "CALICO"
  service_account_id      = yandex_iam_service_account.k8s_master_sa.id
  node_service_account_id = yandex_iam_service_account.k8s_node_sa.id
  kms_provider {
    key_id = yandex_kms_symmetric_key.key.id
  }

  labels = var.labels
  depends_on = [yandex_vpc_subnet.this,
    yandex_resourcemanager_folder_iam_member.service_account_master,
    yandex_resourcemanager_folder_iam_member.service_account_master_2,
    yandex_resourcemanager_folder_iam_member.service_account_master_3,
    yandex_resourcemanager_folder_iam_member.service_account_node,
  null_resource.iam_sleep]
}

### K8s Node Groups

resource "yandex_kubernetes_node_group" "nodes" {
  for_each   = yandex_vpc_subnet.this
  cluster_id = yandex_kubernetes_cluster.regional_cluster.id
  name       = "ng-${each.value.zone}"
  version    = "1.20"

  instance_template {
    platform_id = "standard-v2"
    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
    }
    network_interface {
      nat                = true
      subnet_ids         = [each.value.id]
      security_group_ids = [yandex_vpc_security_group.sg_k8s.id, yandex_vpc_security_group.k8s_public_services.id]
    }

    resources {
      memory = 4
      cores  = 2
    }

    boot_disk {
      type = "network-ssd"
      size = 64
    }

    scheduling_policy {
      preemptible = false
    }
  }

  scale_policy {
    auto_scale {
      min     = 1
      max     = 3
      initial = 1
    }
  }

  allocation_policy {
    location {
      zone = each.value.zone
    }
  }

  maintenance_policy {
    auto_upgrade = true
    auto_repair  = true
  }
  deploy_policy {
    max_expansion   = 2
    max_unavailable = 1
  }
  node_labels = {
    env = "dev"
  }
  node_taints = []
}
### SG
resource "yandex_vpc_security_group" "sg_k8s" {
  name        = "sg-k8s"
  description = "apply this on both cluster and nodes, minimal security group which allows k8s cluster to work"
  network_id  = yandex_vpc_network.this.id
  ingress {
    protocol       = "TCP"
    description    = "allows health_checks from load-balancer health check address range, needed for HA cluster to work as well as for load balancer services to work"
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
    from_port      = 0
    to_port        = 65535
  }
  ingress {
    protocol          = "ANY"
    description       = "allows communication within security group, needed for master-to-node, and node-to-node communication"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }
  ingress {
    protocol       = "ANY"
    description    = "allows pod-pod and service-service communication, change subnets with your cluster and service CIDRs"
    v4_cidr_blocks = [var.k8s_pod_ipv4_range, var.k8s_service_ipv4_range]
    from_port      = 0
    to_port        = 65535
  }
  ingress {
    protocol       = "TCP"
    description    = "allows ssh to nodes from private addresses"
    v4_cidr_blocks = flatten([for v in yandex_vpc_subnet.this : v.v4_cidr_blocks])
    port           = 22
  }
  ingress {
    protocol       = "ICMP"
    description    = "allows icmp from private subnets for troubleshooting"
    v4_cidr_blocks = flatten([for v in yandex_vpc_subnet.this : v.v4_cidr_blocks])
  }
  egress {
    protocol       = "ANY"
    description    = "we usually allow all the egress traffic so that nodes can go outside to s3, registry, dockerhub etc."
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}
resource "yandex_vpc_security_group" "k8s_public_services" {
  name        = "k8s-public-services"
  description = "apply this on nodes, security group that opens up inbound port ranges on nodes, so that your public-facing services can work"
  network_id  = yandex_vpc_network.this.id
  ingress {
    protocol       = "TCP"
    description    = "allows inbound traffic from Internet on NodePort range, apply to nodes, no need to apply on master, change ports or add more rules if using custom ports"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 30000
    to_port        = 32767
  }
}
resource "yandex_vpc_security_group" "k8s_master_whitelist" {
  name        = "k8s-master-whitelist"
  description = "apply this on cluster, to define range of ip-addresses which can access cluster API with kubectl and such"
  network_id  = yandex_vpc_network.this.id
  ingress {
    protocol       = "TCP"
    description    = "whitelist for kubernetes API, controls who can access cluster API from outside, replace with your management ip range"
    v4_cidr_blocks = var.k8s_whitelist
    port           = 6443
  }
  ingress {
    protocol       = "TCP"
    description    = "whitelist for kubernetes API, controls who can access cluster API from outside, replace with your management ip range"
    v4_cidr_blocks = var.k8s_whitelist
    port           = 443
  }
}
