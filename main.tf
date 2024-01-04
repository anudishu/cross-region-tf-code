
#create a VPC
resource "google_compute_network" "default" {
  auto_create_subnetworks = false
  name                    = "my-vpc"
  provider                = google
}


# Create a Subnet in us-west region
resource "google_compute_subnetwork" "subnet_a" {
  provider      = google
  ip_cidr_range = "10.1.2.0/24"
  name          = "lbsubnet-uswest1"
  network       = google_compute_network.default.id
  region        = "us-west1"
}

# Configure Proxy subnet in us-west region
resource "google_compute_subnetwork" "proxy_subnet_a" {
  provider      = google
  ip_cidr_range = "10.129.0.0/23"
  name          = "proxy-only-subnet1"
  network       = google_compute_network.default.id
  purpose       = "GLOBAL_MANAGED_PROXY"
  region        = "us-west1"
  role          = "ACTIVE"
  lifecycle {
    ignore_changes = [ipv6_access_type]
  }
}

# create a subnet in us-east region
resource "google_compute_subnetwork" "subnet_b" {
  provider      = google
  ip_cidr_range = "10.1.3.0/24"
  name          = "lbsubnet-useast1"
  network       = google_compute_network.default.id
  region        = "us-east1"
}

# cofnigre proxy subnet in us-east region
resource "google_compute_subnetwork" "proxy_subnet_b" {
  provider      = google
  ip_cidr_range = "10.130.0.0/23"
  name          = "proxy-only-subnet2"
  network       = google_compute_network.default.id
  purpose       = "GLOBAL_MANAGED_PROXY"
  region        = "us-east1"
  role          = "ACTIVE"
  lifecycle {
    ignore_changes = [ipv6_access_type]
  }
}


#Firewall Rules

#An ingress rule, applicable to the instances being load balanced, that allows all TCP traffic from the Google Cloud health checking systems (in 130.211.0.0/22 and 35.191.0.0/16). 
resource "google_compute_firewall" "fw_healthcheck" {
  name          = "gl7-ilb-fw-allow-hc"
  provider      = google
  direction     = "INGRESS"
  network       = google_compute_network.default.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# An ingress rule, applicable to the instances being load balanced, that allows incoming SSH connectivity on TCP port 22 from any address.
resource "google_compute_firewall" "fw_ilb_to_backends" {
  name          = "fw-ilb-to-fw"
  provider      = google
  network       = google_compute_network.default.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8080"]
  }
}

# An ingress rule, applicable to the instances being load balanced, that allows TCP traffic on ports 80, 443, and 8080 from the internal Application Load Balancer's managed proxies.
resource "google_compute_firewall" "fw_backends" {
  name          = "gl7-ilb-fw-allow-ilb-to-backends"
  direction     = "INGRESS"
  network       = google_compute_network.default.id
  source_ranges = ["10.129.0.0/23", "10.130.0.0/23"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

#Create a managed instance group us-west

resource "google_compute_instance_template" "instance_template_a" {
  name         = "gil7-backendwest1-template"
  provider     = google
  machine_type = "e2-small"
  region       = "us-west1"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.default.id
    subnetwork = google_compute_subnetwork.subnet_a.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = file("web1.sh")
  }
  lifecycle {
    create_before_destroy = true
  }
}

#Create a managed instance group us-east
resource "google_compute_instance_template" "instance_template_b" {
  name         = "gil7-backendeast1-template"
  provider     = google
  machine_type = "e2-small"
  region       = "us-east1"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.default.id
    subnetwork = google_compute_subnetwork.subnet_b.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = file("web1.sh")
  }
  lifecycle {
    create_before_destroy = true
  }
}



#Create Managed Instance Group
resource "google_compute_region_instance_group_manager" "mig_a" {
  name     = "gl7-ilb-miga"
  provider = google
  region   = "us-west1"
  version {
    instance_template = google_compute_instance_template.instance_template_a.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

resource "google_compute_region_instance_group_manager" "mig_b" {
  name     = "gl7-ilb-migb"
  provider = google
  region   = "us-east1"
  version {
    instance_template = google_compute_instance_template.instance_template_b.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}


#Configure the load balancer

#A global HTTP health check.
resource "google_compute_health_check" "default" {
  provider = google
  name     = "global-http-health-check"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

#A global backend service with the managed instance groups as the backend.
resource "google_compute_backend_service" "default" {
  name                  = "gl7-gilb-backend-service"
  provider              = google
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.mig_a.instance_group #us-west
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
  backend {
    group           = google_compute_region_instance_group_manager.mig_b.instance_group #us-east
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

#URL Map
resource "google_compute_url_map" "default" {
  name            = "gl7-gilb-url-map"
  provider        = google
  default_service = google_compute_backend_service.default.id
}

#A global target proxy.
resource "google_compute_target_http_proxy" "default" {
  name     = "gil7target-http-proxy"
  provider = google
  url_map  = google_compute_url_map.default.id
}


#Two global forwarding rules with regional IP addresses. For the forwarding rule's IP address, use the lbsubnet-uswest1 or lbsubnet-useast1 IP address range.

resource "google_compute_global_forwarding_rule" "fwd_rule_a" {
  provider              = google
  depends_on            = [google_compute_subnetwork.proxy_subnet_a]
  ip_address            = "10.1.2.99"
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  name                  = "gil7forwarding-rule-a"
  network               = google_compute_network.default.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  subnetwork            = google_compute_subnetwork.subnet_a.id
}

resource "google_compute_global_forwarding_rule" "fwd_rule_b" {
  provider              = google
  depends_on            = [google_compute_subnetwork.proxy_subnet_b]
  ip_address            = "10.1.3.99"
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  name                  = "gil7forwarding-rule-b"
  network               = google_compute_network.default.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  subnetwork            = google_compute_subnetwork.subnet_b.id
}
