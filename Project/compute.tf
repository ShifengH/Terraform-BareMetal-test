variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "compartment_ocid" {}
variable "ssh_public_key" {}
variable "ssh_private_key" {}

# Choose an Availability Domain
variable "AD" {
    default = "1"
}
variable "InstanceShape" {
    default = "VM.Standard1.2"
}
variable "InstanceOS" {
    default = "Oracle Linux"
}

variable "InstanceOSVersion" {
    default = "7.3"
}

variable "2TB" {
    default = "2097152"
}

variable "256GB" {
    default = "262144"
}

variable "BootStrapFile" {
    default = "./userdata/bootstrap"
}

provider "baremetal" {
  tenancy_ocid = "${var.tenancy_ocid}"
  user_ocid = "${var.user_ocid}"
  fingerprint = "${var.fingerprint}"
  private_key_path = "${var.private_key_path}"
  disable_auto_retries = "true"
}

# Gets a list of Availability Domains
data "baremetal_identity_availability_domains" "ADs" {
  compartment_id = "${var.tenancy_ocid}"
}

# Gets the OCID of the OS image to use
data "baremetal_core_images" "OLImageOCID" {
    compartment_id = "${var.compartment_ocid}"
    operating_system = "${var.InstanceOS}"
    operating_system_version = "${var.InstanceOSVersion}"
}

# Gets a list of vNIC attachments on the instance
data "baremetal_core_vnic_attachments" "InstanceVnics" {
compartment_id = "${var.compartment_ocid}"
availability_domain = "${lookup(data.baremetal_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
instance_id = "${baremetal_core_instance.TFInstance.id}"
}

# Gets the OCID of the first (default) vNIC
data "baremetal_core_vnic" "InstanceVnic" {
vnic_id = "${lookup(data.baremetal_core_vnic_attachments.InstanceVnics.vnic_attachments[0],"vnic_id")}"
}



/* Network */

resource "baremetal_core_virtual_network" "vcn1" {
    cidr_block = "10.1.0.0/16"
    compartment_id = "${var.compartment_ocid}"
    display_name = "vcn1"
    dns_label = "vcn1"
}

resource "baremetal_core_subnet" "subnet1" {
    availability_domain = "${lookup(data.baremetal_identity_availability_domains.ADs.availability_domains[0],"name")}"
    cidr_block = "10.1.20.0/24"
    display_name = "subnet1"
    dns_label = "subnet1"
    security_list_ids = ["${baremetal_core_security_list.securitylist1.id}"]
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${baremetal_core_virtual_network.vcn1.id}"
    route_table_id = "${baremetal_core_route_table.routetable1.id}"
    dhcp_options_id = "${baremetal_core_virtual_network.vcn1.default_dhcp_options_id}"

    provisioner "local-exec" {
        command = "sleep 5"
    }
}


resource "baremetal_core_internet_gateway" "internetgateway1" {
    compartment_id = "${var.compartment_ocid}"
    display_name = "internetgateway1"
    vcn_id = "${baremetal_core_virtual_network.vcn1.id}"
}

resource "baremetal_core_route_table" "routetable1" {
    compartment_id = "${var.compartment_ocid}"
    vcn_id = "${baremetal_core_virtual_network.vcn1.id}"
    display_name = "routetable1"
    route_rules {
        cidr_block = "0.0.0.0/0"
        network_entity_id = "${baremetal_core_internet_gateway.internetgateway1.id}"
    }
}

resource "baremetal_core_security_list" "securitylist1" {
  display_name   = "public"
  compartment_id = "${baremetal_core_virtual_network.vcn1.compartment_id}"
  vcn_id         = "${baremetal_core_virtual_network.vcn1.id}"

  egress_security_rules = [{
    protocol    = "all"
    destination = "0.0.0.0/0"
  }]

  ingress_security_rules = [
    {
      protocol = "6"
      source   = "0.0.0.0/0"

      tcp_options {
        "min" = 80
        "max" = 80
      }
    },
    {
      protocol = "6"
      source   = "0.0.0.0/0"

# Port 22, for SSH connection, otherwise the Instance is not able to connected.
      tcp_options {
        "min" = 22
        "max" = 22
      }
    },
    {
      protocol = "6"
      source   = "0.0.0.0/0"

      tcp_options {
        "min" = 443
        "max" = 443
      }
    },
  ]
}


/* Instance creation */

resource "baremetal_core_instance" "TFInstance" {
  availability_domain = "${lookup(data.baremetal_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}" 
  compartment_id = "${var.compartment_ocid}"
  display_name = "TFInstance"
  hostname_label = "instance1"
  image = "${lookup(data.baremetal_core_images.OLImageOCID.images[0], "id")}"
  shape = "${var.InstanceShape}"
  subnet_id = "${baremetal_core_subnet.subnet1.id}"
  metadata {
    ssh_authorized_keys = "${var.ssh_public_key}"
    user_data = "${base64encode(file(var.BootStrapFile))}"
  }

  timeouts {
    create = "60m"
  }
}

/* block Storage defination */


resource "baremetal_core_volume" "TFBlock0" {
  availability_domain = "${lookup(data.baremetal_identity_availability_domains.ADs.availability_domains[var.AD - 1],"name")}"
  compartment_id = "${var.compartment_ocid}"
  display_name = "TFBlock0"
  size_in_mbs = "${var.256GB}"
}


## attach iscsi #

resource "baremetal_core_volume_attachment" "TFBlock0Attach" {
    attachment_type = "iscsi"
    compartment_id = "${var.compartment_ocid}"
    instance_id = "${baremetal_core_instance.TFInstance.id}"
    volume_id = "${baremetal_core_volume.TFBlock0.id}"
}
resource "null_resource" "remote-exec" {
    depends_on = ["baremetal_core_instance.TFInstance","baremetal_core_volume_attachment.TFBlock0Attach"]
    provisioner "remote-exec" {
      connection {
        agent = false
        timeout = "30m"
        host = "${data.baremetal_core_vnic.InstanceVnic.public_ip_address}"
        user = "opc"
        private_key = "${var.ssh_private_key}"
    }
      inline = [
        "touch ~/IMadeAFile.Right.Here",
        "sudo iscsiadm -m node -o new -T ${baremetal_core_volume_attachment.TFBlock0Attach.iqn} -p ${baremetal_core_volume_attachment.TFBlock0Attach.ipv4}:${baremetal_core_volume_attachment.TFBlock0Attach.port}",
        "sudo iscsiadm -m node -o update -T ${baremetal_core_volume_attachment.TFBlock0Attach.iqn} -n node.startup -v automatic",
        "echo sudo iscsiadm -m node -T ${baremetal_core_volume_attachment.TFBlock0Attach.iqn} -p ${baremetal_core_volume_attachment.TFBlock0Attach.ipv4}:${baremetal_core_volume_attachment.TFBlock0Attach.port} -l >> ~/.bashrc"
      ]
    }
}


# Output the private and public IPs of the instance

output "InstancePrivateIP" {
value = ["${data.baremetal_core_vnic.InstanceVnic.private_ip_address}"]
}

output "InstancePublicIP" {
value = ["${data.baremetal_core_vnic.InstanceVnic.public_ip_address}"]
}

