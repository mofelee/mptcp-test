# Two Debian 13 hosts with two isolated MPTCP data paths.
# Libvirt owns link bandwidth; DebianForm owns all guest configuration.

script "reconfigure_client_data_links" {
  mode = "once"

  content = <<-EOF
    find_interface() {
      wanted="$1"
      for link in /sys/class/net/*; do
        test "$(cat "$link/address")" = "$wanted" || continue
        basename "$link"
        return 0
      done
      return 1
    }

    for mac in 52:54:00:ca:01:01 52:54:00:cb:01:01; do
      interface="$(find_interface "$mac")"
      networkctl reconfigure "$interface"
    done
  EOF
}

script "reconfigure_server_data_links" {
  mode = "once"

  content = <<-EOF
    find_interface() {
      wanted="$1"
      for link in /sys/class/net/*; do
        test "$(cat "$link/address")" = "$wanted" || continue
        basename "$link"
        return 0
      done
      return 1
    }

    for mac in 52:54:00:ca:02:01 52:54:00:cb:02:01; do
      interface="$(find_interface "$mac")"
      networkctl reconfigure "$interface"
    done
  EOF
}

host "client" {
  ssh {
    host = "mptcp-client"
    user = "root"
  }

  platform {
    distribution = "debian"
    version      = "13"
    architecture = "amd64"
    codename     = "trixie"
  }

  system {
    hostname = "mptcp-client"
    timezone = "UTC"
  }

  kernel {
    sysctl = {
      "net.ipv4.conf.all.rp_filter"     = "2"
      "net.ipv4.conf.default.rp_filter" = "2"
      "net.mptcp.enabled"               = "1"
      "net.mptcp.pm_type"               = "0"
    }
  }

  packages {
    package "iperf3" {
      conffile_policy = "keep"
    }
    package "iproute2" {
      conffile_policy = "keep"
    }
    package "mptcpize" {
      conffile_policy = "keep"
    }
  }

  files {
    file "/usr/local/sbin/mptcp-lab-setup" {
      depends_on = [package.iproute2]
      owner      = "root"
      group      = "root"
      mode       = "0755"

      content = <<-EOF
        #!/bin/sh
        set -eu

        wait_for_address() {
          address="$1"
          attempt=0
          while ! ip -o -4 address show | grep -Fq " $address/"; do
            attempt=$((attempt + 1))
            if test "$attempt" -ge 60; then
              echo "timed out waiting for $address" >&2
              exit 1
            fi
            sleep 1
          done
        }

        wait_for_address 10.203.1.1
        wait_for_address 10.203.2.1
        ip mptcp endpoint flush
        ip mptcp limits set subflow 1 add_addr_accepted 1
      EOF
    }
  }

  systemd {
    networkd {
      enable = true

      network "20-mptcp-link-a" {
        section "match" {
          name = "Match"
          settings = {
            MACAddress = "52:54:00:ca:01:01"
          }
        }
        section "link" {
          name = "Link"
          settings = {
            RequiredForOnline = false
          }
        }
        section "network" {
          name = "Network"
          settings = {
            Address             = "10.203.1.1/30"
            DHCP                = "no"
            IPv6AcceptRA        = false
            LinkLocalAddressing = "no"
          }
        }
        activation {
          post_reload = script.reconfigure_client_data_links
        }
      }

      network "21-mptcp-link-b" {
        section "match" {
          name = "Match"
          settings = {
            MACAddress = "52:54:00:cb:01:01"
          }
        }
        section "link" {
          name = "Link"
          settings = {
            RequiredForOnline = false
          }
        }
        section "network" {
          name = "Network"
          settings = {
            Address             = "10.203.2.1/30"
            DHCP                = "no"
            IPv6AcceptRA        = false
            LinkLocalAddressing = "no"
          }
        }
        activation {
          post_reload = script.reconfigure_client_data_links
        }
      }
    }

    service_unit "mptcp-lab-setup" {
      change_action = "restart"

      content = <<-EOF
        [Unit]
        Description=Configure the MPTCP lab path manager
        Wants=network-online.target
        After=network-online.target systemd-networkd.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/sbin/mptcp-lab-setup
        ExecReload=/usr/local/sbin/mptcp-lab-setup
        ExecStop=/usr/sbin/ip mptcp endpoint flush

        [Install]
        WantedBy=multi-user.target
      EOF
    }
  }

  services {
    service "mptcp-lab-setup" {
      depends_on = [file["/usr/local/sbin/mptcp-lab-setup"]]
      enabled    = true
      state      = "running"
    }
  }
}

host "server" {
  ssh {
    host = "mptcp-server"
    user = "root"
  }

  platform {
    distribution = "debian"
    version      = "13"
    architecture = "amd64"
    codename     = "trixie"
  }

  system {
    hostname = "mptcp-server"
    timezone = "UTC"
  }

  kernel {
    sysctl = {
      "net.ipv4.conf.all.rp_filter"     = "2"
      "net.ipv4.conf.default.rp_filter" = "2"
      "net.mptcp.enabled"               = "1"
      "net.mptcp.pm_type"               = "0"
    }
  }

  packages {
    package "iperf3" {
      conffile_policy = "keep"
    }
    package "iproute2" {
      conffile_policy = "keep"
    }
    package "mptcpize" {
      conffile_policy = "keep"
    }
  }

  files {
    file "/usr/local/sbin/mptcp-lab-setup" {
      depends_on = [package.iproute2]
      owner      = "root"
      group      = "root"
      mode       = "0755"

      content = <<-EOF
        #!/bin/sh
        set -eu

        wait_for_address() {
          address="$1"
          attempt=0
          while ! ip -o -4 address show | grep -Fq " $address/"; do
            attempt=$((attempt + 1))
            if test "$attempt" -ge 60; then
              echo "timed out waiting for $address" >&2
              exit 1
            fi
            sleep 1
          done
        }

        wait_for_address 10.203.1.2
        wait_for_address 10.203.2.2
        ip mptcp endpoint flush
        ip mptcp limits set subflow 1 add_addr_accepted 0
        interface="$(ip -o route get 10.203.2.1 from 10.203.2.2 | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
        test -n "$interface"
        ip mptcp endpoint add 10.203.2.2 dev "$interface" id 1 signal
      EOF
    }
  }

  systemd {
    networkd {
      enable = true

      network "20-mptcp-link-a" {
        section "match" {
          name = "Match"
          settings = {
            MACAddress = "52:54:00:ca:02:01"
          }
        }
        section "link" {
          name = "Link"
          settings = {
            RequiredForOnline = false
          }
        }
        section "network" {
          name = "Network"
          settings = {
            Address             = "10.203.1.2/30"
            DHCP                = "no"
            IPv6AcceptRA        = false
            LinkLocalAddressing = "no"
          }
        }
        activation {
          post_reload = script.reconfigure_server_data_links
        }
      }

      network "21-mptcp-link-b" {
        section "match" {
          name = "Match"
          settings = {
            MACAddress = "52:54:00:cb:02:01"
          }
        }
        section "link" {
          name = "Link"
          settings = {
            RequiredForOnline = false
          }
        }
        section "network" {
          name = "Network"
          settings = {
            Address             = "10.203.2.2/30"
            DHCP                = "no"
            IPv6AcceptRA        = false
            LinkLocalAddressing = "no"
          }
        }
        activation {
          post_reload = script.reconfigure_server_data_links
        }
      }
    }

    service_unit "mptcp-lab-setup" {
      change_action = "restart"

      content = <<-EOF
        [Unit]
        Description=Configure the MPTCP lab path manager
        Wants=network-online.target
        After=network-online.target systemd-networkd.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/sbin/mptcp-lab-setup
        ExecReload=/usr/local/sbin/mptcp-lab-setup
        ExecStop=/usr/sbin/ip mptcp endpoint flush

        [Install]
        WantedBy=multi-user.target
      EOF
    }

    service_unit "iperf3-tcp" {
      description = "Plain TCP iperf3 server for the MPTCP lab"
      run         = ["/usr/bin/iperf3", "--version4", "--server", "--port", "5201"]
      restart     = "on-failure"
      after       = ["network-online.target"]
    }

    service_unit "iperf3-mptcp" {
      description = "MPTCP iperf3 server for the MPTCP lab"
      run         = ["/usr/bin/mptcpize", "run", "/usr/bin/iperf3", "--version4", "--server", "--port", "5202"]
      restart     = "on-failure"
      after       = ["mptcp-lab-setup.service"]
    }
  }

  services {
    service "mptcp-lab-setup" {
      depends_on = [file["/usr/local/sbin/mptcp-lab-setup"]]
      enabled    = true
      state      = "running"
    }

    service "iperf3-tcp" {
      package = "iperf3"
      enabled = true
      state   = "running"
    }

    service "iperf3-mptcp" {
      depends_on = [package.iperf3, package.mptcpize, service.mptcp-lab-setup]
      enabled    = true
      state      = "running"
    }
  }
}
