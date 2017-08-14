#!/usr/bin/env bash
set -e
set -v
set -x
local_ipv4=$(hostname -I | awk 'FNR == 1 {print $1}')
cluster_size=3

# stop consul and nomad so they can be configured correctly
sudo systemctl stop nomad
sudo systemctl stop consul

# clear the consul and nomad data directory ready for a fresh start
sudo rm -rf /opt/consul/data/*
sudo rm -rf /opt/nomad/data/*

sleep 60s

sudo sed -i -e "s/127.0.0.1/${local_ipv4}/" /etc/consul.d/consul-default.json

# add the cluster instance count to the config with jq
sudo jq ".bootstrap_expect = ${cluster_size}" < /etc/consul.d/consul-server.json > /tmp/consul-server.json.tmp
sudo mv /tmp/consul-server.json.tmp /etc/consul.d/consul-server.json
sudo chown consul:consul /etc/consul.d/consul-server.json

echo "advertise {
  http = \"${local_ipv4}\"
  rpc = \"${local_ipv4}\"
  serf = \"${local_ipv4}\"
}" | tee -a /etc/nomad.d/nomad-default.hcl

# add the cluster instance count to the nomad server config
sed -e "s/bootstrap_expect = 1/bootstrap_expect = ${cluster_size}/g" /etc/nomad.d/nomad-server.hcl > /tmp/nomad-server.hcl.tmp
mv /tmp/nomad-server.hcl.tmp /etc/nomad.d/nomad-server.hcl


sudo systemctl start consul
sudo systemctl start nomad

sleep 5s

consul join 10.128.0.2 10.128.0.3 10.128.0.4


echo 'job "fabio" {
  datacenters = ["dc1"]
  type = "system"
  update {
    stagger = "5s"
    max_parallel = 1
  }

  group "fabio" {
    task "fabio" {
      driver = "exec"
      config {
        command = "fabio"
      }

      artifact {
        source = "https://s3.amazonaws.com/ak-bucket-1/fabio"
      }

      resources {
        cpu = 500
        memory = 64
        network {
          mbits = 1

          port "http" {
            static = 9999
          }
          port "ui" {
            static = 9998
          }
        }
      }
    }
  }
}
' | tee -a /tmp/fabio.nomad

echo 'job "hdfs" {

  datacenters = [ "dc1" ]

  group "NameNode" {

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    task "NameNode" {

      driver = "docker"

      config {
        image = "rcgenova/hadoop-2.7.3"
        command = "bash"
        args = [ "-c", "hdfs namenode -format && exec hdfs namenode -D fs.defaultFS=hdfs://$${NOMAD_ADDR_ipc}/ -D dfs.permissions.enabled=false" ]
        network_mode = "host"
        port_map {
          ipc = 8020
          ui = 50070
        }
      }

      resources {
        memory = 500
        network {
          port "ipc" {
            static = "8020"
          }
          port "ui" {
            static = "50070"
          }
        }
      }

      service {
        name = "hdfs"
        port = "ipc"
      }
    }
  }

  group "DataNode" {

    count = 3

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    task "DataNode" {

      driver = "docker"

      config {
        network_mode = "host"
        image = "rcgenova/hadoop-2.7.3"
        args = [ "hdfs", "datanode"
          , "-D", "fs.defaultFS=hdfs://hdfs.service.consul/"
          , "-D", "dfs.permissions.enabled=false"
        ]
        port_map {
          data = 50010
          ipc = 50020
          ui = 50075
        }
      }

      resources {
        memory = 500
        network {
          port "data" {
            static = "50010"
          }
          port "ipc" {
            static = "50020"
          }
          port "ui" {
            static = "50075"
          }
        }
      }

    }
  }

}' | tee -a /tmp/hdfs.nomad

echo 'job "spark-history-server" {
  datacenters = ["dc1"]
  type = "service"

  group "server" {
    count = 1

    task "history-server" {
      driver = "docker"

      config {
        image = "barnardb/spark"
        command = "/spark/spark-2.1.0-bin-nomad/bin/spark-class"
        args = [ "org.apache.spark.deploy.history.HistoryServer" ]
        port_map {
          ui = 18080
        }
        network_mode = "host"
      }

      env {
        "SPARK_HISTORY_OPTS" = "-Dspark.history.fs.logDirectory=hdfs://hdfs.service.consul/spark-events/"
        "SPARK_PUBLIC_DNS"   = "spark-history.service.consul"
      }

      resources {
        cpu    = 500
        memory = 500
        network {
          mbits = 250
          port "ui" {
            static = 18080
          }
        }
      }

      service {
        name = "spark-history"
        tags = ["spark", "ui"]
        port = "ui"
      }
    }

  }
}' | tee -a /tmp/spark-history-server.nomad


echo 'job "nginx" {
  datacenters = ["dc1"]
  type = "service"

  group "nginx" {
    count = 3

    task "nginx" {
      driver = "docker"

      config {
        image = "nginx"
        port_map {
          http = 80
        }
        port_map {
          https = 443
        }
        volumes = [
          "custom/default.conf:/etc/nginx/conf.d/default.conf",
          "secret/cert.key:/etc/nginx/ssl/nginx.key",
        ]
      }

      template {
        data = <<EOH
          server {

	    listen 80;

            server_name nginx.service.consul;
            # note this is slightly wonky using the same file for
            # both the cert and key
            #ssl_certificate /etc/nginx/ssl/nginx.key;
            #ssl_certificate_key /etc/nginx/ssl/nginx.key;

            location / {
              root /local/data/;
            }
          }
        EOH

        destination = "custom/default.conf"
      }

      template {
        data = <<EOH
            Good morning.
        EOH

        destination = "local/data/index.html"
      }

      resources {
        cpu    = 100 # 100 MHz
        memory = 128 # 128 MB
        network {
          mbits = 10
          port "http" {
            static = 80
          }
          port "https" {
            static = 443
          }
        }
      }

      service {
        name = "nginx"
        tags = ["frontend","urlprefix-/nginx strip=/nginx"]
        port = "http"
        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}' | tee -a /tmp/nginx.nomad

echo 'job "app" {
  datacenters = ["dc1"]
  type = "service"
  update {
    max_parallel = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert = false
    canary = 0
  }
  group "app" {
    count = 3

    restart {
      # The number of attempts to run the job within the specified interval.
      attempts = 10
      interval = "5m"

      # The "delay" parameter specifies the duration to wait before restarting
      # a task after it has failed.
      delay = "25s"

      mode = "delay"
    }

    ephemeral_disk {
      size = 300
    }

    task "app" {
      # The "driver" parameter specifies the task driver that should be used to
      # run the task.
      driver = "docker"

      config {
        image = "aklaas2/test-app"
        port_map {
          http = 8080
        }
      }
      resources {
        cpu    = 500 # 500 MHz
        memory = 256 # 256MB
        network {
          mbits = 10
          port "http" {
		          static=8080
	        }
        }
      }
      service {
        name = "app"
        tags = [ "urlprefix-app/"]
        port = "http"
        check {
          name     = "alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}'

## Download and unpack spark
sudo wget -P /ops/examples/spark https://s3.amazonaws.com/nomad-spark/spark-2.1.0-bin-nomad.tgz
sudo tar -xvf /ops/examples/spark/spark-2.1.0-bin-nomad.tgz --directory /ops/examples/spark
sudo mv /ops/examples/spark/spark-2.1.0-bin-nomad /usr/local/bin/spark
sudo chown -R root:root /usr/local/bin/spark

export HADOOP_VERSION=2.7.3
#HDFS
wget -O - http://apache.mirror.iphh.net/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz | sudo tar xz -C /usr/local

#Configure Hadoop CLI
HADOOPCONFIGDIR=/usr/local/hadoop-$HADOOP_VERSION/etc/hadoop
sudo bash -c "cat >$HADOOPCONFIGDIR/core-site.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://hdfs.service.consul/</value>
    </property>
</configuration>
EOF

YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)
if [[ ! -z $${YUM} ]]; then
  export HOME_DIR=ec2-user
elif [[ ! -z $${APT_GET} ]]; then
  export HOME_DIR=ubuntu
fi

echo "export JAVA_HOME=/usr/"  | sudo tee --append /home/$HOME_DIR/.bashrc
echo "export PATH=$PATH:/usr/local/bin/spark/bin:/usr/local/hadoop-$HADOOP_VERSION/bin" | sudo tee --append /home/$HOME_DIR/.bashrc
