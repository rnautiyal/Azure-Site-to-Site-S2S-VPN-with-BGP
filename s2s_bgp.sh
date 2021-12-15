#!/bin/bash
# This scripts simulates Azure S2S VPN with BGP.
# variables
cloud_location='uaenorth'
site1_location='westeurope'
site2_location='australiacentral'
cloud_rg_name='s2s-bgp-cloud'
cloud_vnet_name='cloud-vnet'
cloud_vnet_address='10.10.0.0/16'
cloud_mgmt_subnet_name='mgmt-subnet'
cloud_mgmt_subnet_address='10.10.1.0/24'
cloud_gatewaysubnet_address='10.10.0.0/24'
cloud_gw_name='cloud-gw'
cloud_gw_asn=65010
cloud_vm_name='cloud-linvm'
site1_rg_name='s2s-bgp-site1'
site1_vnet_name='site1-vnet'
site1_vnet_address='192.168.0.0/16'
site1_lan_subnet_name='lan-subnet'
site1_lan_subnet_address='192.168.1.0/24'
site1_dmz_subnet_name='dmz-subnet'
site1_dmz_subnet_address='192.168.0.0/24'
site1_gw_name='site1-gw'
site1_gw_vti_address='192.168.0.254'
site1_gw_asn=65051
site1_vm_name='site1-linvm'
site2_rg_name='s2s-bgp-site2'
site2_vnet_name='site2-vnet'
site2_vnet_address='172.16.0.0/16'
site2_lan_subnet_name='lan-subnet'
site2_lan_subnet_address='172.16.1.0/24'
site1_dmz_subnet_name='dmz-subnet'
site2_dmz_subnet_address='172.16.0.0/24'
site2_gw_name='site2-gw'
site2_gw_vti_address='172.16.0.254'
site2_gw_asn=65052
site2_vm_name='site2-linvm'
psksecret=secret12345
tag="scenario=s2s-bgp-bgp"
site_gw_cloudinit_file=/tmp/site_gw_cloudinit.txt
cat <<EOF > $site_gw_cloudinit_file
#cloud-config
runcmd:
  - apt-get update -y && apt-get dist-upgrade -y && apt autoremove -y
  - apt install quagga quagga-doc strongswan -y
  - cp /usr/share/doc/quagga-core/examples/vtysh.conf.sample /etc/quagga/vtysh.conf
  - cp /usr/share/doc/quagga-core/examples/zebra.conf.sample /etc/quagga/zebra.conf
  - cp /usr/share/doc/quagga-core/examples/bgpd.conf.sample /etc/quagga/bgpd.conf
  - chown quagga:quagga /etc/quagga/*.conf
  - chown quagga:quaggavty /etc/quagga/vtysh.conf
  - chmod 640 /etc/quagga/*.conf
  - service zebra start
  - service bgpd start
  - systemctl enable zebra.service
  - systemctl enable bgpd.service
  - touch /etc/strongswan.d/ipsec-vti.sh
  - chmod +x /etc/strongswan.d/ipsec-vti.sh
  - cp /etc/ipsec.conf /etc/ipsec.conf.bak
  - cp /etc/ipsec.secrets /etc/ipsec.secrets.bak
  - sysctl -w net.ipv4.ip_forward=1
  - sysctl -w net.ipv4.conf.all.accept_redirects=0 
  - sysctl -w net.ipv4.conf.all.send_redirects=0
EOF

function wait_until_finished {
     wait_interval=15
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo -e "\e[1;36m Waiting for resource $resource_name to finish provisioning...\e[0m"
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
        echo "Something really bad happened..."
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        echo -e "\e[1;32mResource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds\e[0m"
     fi
}
# resource groups
echo -e "\e[1;36m Deploying Resource Groups \e[0m"
az group create --location $cloud_location -n $cloud_rg_name --tags $tag
az group create --location $site1_location -n $site1_rg_name --tags $tag
az group create --location $site2_location -n $site2_rg_name --tags $tag

echo -e "\e[1;36m Deploying $cloud_vnet_name\e[0m"
# cloud-vnet
az network vnet create -g $cloud_rg_name -n $cloud_vnet_name --address-prefixes $cloud_vnet_address --subnet-name $cloud_mgmt_subnet_name --subnet-prefixes $cloud_mgmt_subnet_address --tags $tag
az network vnet subnet create --address-prefixes $cloud_gatewaysubnet_address -n gatewaysubnet -g $cloud_rg_name --vnet-name $cloud_vnet_name
# cloud-nsg
echo -e "\e[1;36m Deploying cloud-nsg\e[0m"
az network nsg create -n cloud-nsg -g $cloud_rg_name --tags $tag
az network nsg rule create -n allow_ssh --nsg-name cloud-nsg -g $cloud_rg_name --priority 100 --access allow --protocol tcp --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --direction Inbound
az network nsg rule create -n allow_icmp --nsg-name cloud-nsg -g $cloud_rg_name --priority 101 --access allow --protocol Icmp --source-address-prefixes '*' --destination-address-prefixes '*' --destination-port-ranges '*' --direction Inbound
az network vnet subnet update -n $cloud_mgmt_subnet_name -g  $cloud_rg_name --vnet-name $cloud_vnet_name --nsg cloud-nsg
# Cloud vpn gateway
echo -e "\e[1;36m Deploying $cloud_gw_name\e[0m"
az network public-ip create -n "$cloud_gw_name-pubip" -g $cloud_rg_name --allocation-method dynamic --sku basic --tags $tag
az network vnet-gateway create -n $cloud_gw_name --public-ip-addresses "$cloud_gw_name-pubip" -g $cloud_rg_name --vnet $cloud_vnet_name --gateway-type vpn --sku vpngw1 --vpn-type routebased --asn $cloud_gw_asn --tags $tag --no-wait
# cloud-vm (linux)
echo -e "\e[1;36m Deploying $cloud_vm_name\e[0m"
az network public-ip create -n "$cloud_vm_name-pubip" -g $cloud_rg_name --allocation-method static --sku basic --tags $tag
az network nic create -n "$cloud_vm_name-nic" --vnet-name $cloud_vnet_name -g $cloud_rg_name --subnet $cloud_mgmt_subnet_name --private-ip-address 10.10.1.6 --public-ip-address "$cloud_vm_name-pubip" --tags $tag
az vm create -n $cloud_vm_name -g $cloud_rg_name --image ubuntults --nics "$cloud_vm_name-nic" --os-disk-name "$cloud_vm_name-os-disk" --size standard_b1s --generate-ssh-keys --tags $tag --no-wait

echo -e "\e[1;36m Deploying $site1_vnet_name\e[0m"
# site1-vnet
az network vnet create -g $site1_rg_name -n $site1_vnet_name --address-prefixes $site1_vnet_address --subnet-name $site1_lan_subnet_name --subnet-prefixes $site1_lan_subnet_address --tags $tag
az network vnet subnet create --address-prefixes $site1_dmz_subnet_address -n $site1_dmz_subnet_name -g $site1_rg_name --vnet-name $site1_vnet_name
#site1-nsg
echo -e "\e[1;36m Deploying site1-nsg\e[0m"
az network nsg create -n site1-nsg -g $site1_rg_name --tags $tag
az network nsg rule create -n allow_ssh --nsg-name site1-nsg -g $site1_rg_name --priority 100 --access allow --protocol tcp --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --direction Inbound
az network nsg rule create -n allow_icmp --nsg-name site1-nsg -g $site1_rg_name --priority 101 --access allow --protocol Icmp --source-address-prefixes '*' --destination-address-prefixes '*' --destination-port-ranges '*' --direction Inbound
az network vnet subnet update -n $site1_lan_subnet_name -g  $site1_rg_name --vnet-name $site1_vnet_name --nsg site1-nsg
# site1-gw vm
echo -e "\e[1;36m Deploying $site1_gw_name\e[0m"
az network public-ip create -n "$site1_gw_name-pubip" -g $site1_rg_name --allocation-method static --sku basic --tags $tag
az network nic create -n "$site1_gw_name-dmz-nic" --vnet-name $site1_vnet_name -g $site1_rg_name --subnet $site1_dmz_subnet_name --ip-forwarding true --private-ip-address 192.168.0.4 --public-ip-address "$site1_gw_name-pubip" --tags $tag
az vm create -n $site1_gw_name -g $site1_rg_name --image ubuntults --nics "$site1_gw_name-dmz-nic" --os-disk-name "$site1_gw_name-os-disk" --size standard_b1s --generate-ssh-keys --custom-data $site_gw_cloudinit_file --tags $tag --no-wait
# site1-vm (linux)
echo -e "\e[1;36m Deploying $site1_vm_name\e[0m"
az network public-ip create -n "$site1_vm_name-pubip" -g $site1_rg_name --allocation-method static --sku basic --tags $tag
az network nic create -n "$site1_vm_name-nic" --vnet-name $site1_vnet_name -g $site1_rg_name --subnet $site1_lan_subnet_name --private-ip-address 192.168.1.6 --public-ip-address "$site1_vm_name-pubip" --tags $tag
az vm create -n $site1_vm_name -g $site1_rg_name --image ubuntults --nics "$site1_vm_name-nic" --os-disk-name "$site1_vm_name-os-disk" --size standard_b1s --generate-ssh-keys --tags $tag --no-wait

# get site1 gw details
echo -e "\e[1;36m Getting $site1_gw_name details\e[0m"
site1_gw_vm_id=$(az vm show -n $site1_gw_name -g $site1_rg_name --query 'id' -o tsv)
wait_until_finished $site1_gw_vm_id
site1_gw_nic_id=$(az vm show -n $site1_gw_name -g $site1_rg_name --query 'networkProfile.networkInterfaces[0].id' -o tsv)
site1_gw_pip=$(az network public-ip show -n "$site1_gw_name-pubip" -g $site1_rg_name --query ipAddress -o tsv) && echo $site1_gw_pip
site1_gw_private_ip=$(az network nic show --ids $site1_gw_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo $site1_gw_private_ip

echo -e "\e[1;36m Deploying $site2_vnet_name\e[0m"
# site2-vnet
az network vnet create -g $site2_rg_name -n $site2_vnet_name --address-prefixes $site2_vnet_address --subnet-name $site2_lan_subnet_name --subnet-prefixes $site2_lan_subnet_address --tags $tag
az network vnet subnet create --address-prefixes $site2_dmz_subnet_address -n $site1_dmz_subnet_name -g $site2_rg_name --vnet-name $site2_vnet_name
#site2-nsg
echo -e "\e[1;36m Deploying site2-nsg\e[0m"
az network nsg create -n site2-nsg -g $site2_rg_name --tags $tag
az network nsg rule create -n allow_ssh --nsg-name site2-nsg -g $site2_rg_name --priority 100 --access allow --protocol tcp --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22
az network nsg rule create -n allow_icmp --nsg-name site2-nsg -g $site2_rg_name --priority 101 --access allow --protocol Icmp --source-address-prefixes '*' --destination-address-prefixes '*' --destination-port-ranges '*'
az network vnet subnet update -n $site2_lan_subnet_name -g  $site2_rg_name --vnet-name $site2_vnet_name --nsg site2-nsg
# site2-gateway vm
echo -e "\e[1;36m Deploying $site2_gw_name\e[0m"
az network public-ip create -n "$site2_gw_name-pubip" -g $site2_rg_name --allocation-method static --sku basic --tags $tag
az network nic create -n "$site2_gw_name-dmz-nic" --vnet-name $site2_vnet_name -g $site2_rg_name --subnet $site1_dmz_subnet_name --ip-forwarding true --private-ip-address 172.16.0.4 --public-ip-address "$site2_gw_name-pubip" --tags $tag
az vm create -n $site2_gw_name -g $site2_rg_name --image ubuntults --nics "$site2_gw_name-dmz-nic" --os-disk-name "$site2_gw_name-os-disk" --size standard_b1s --generate-ssh-keys --custom-data $site_gw_cloudinit_file --tags $tag --no-wait
# site2-vm (linux)
echo -e "\e[1;36m Deploying $site2_vm_name\e[0m"
az network public-ip create -n "$site2_vm_name-pubip" -g $site2_rg_name --allocation-method static --sku basic --tags $tag
az network nic create -n "$site2_vm_name-nic" --vnet-name $site2_vnet_name -g $site2_rg_name --subnet $site2_lan_subnet_name --private-ip-address 172.16.1.6 --public-ip-address "$site2_vm_name-pubip" --tags $tag
az vm create -n $site2_vm_name -g $site2_rg_name --image ubuntults --nics "$site2_vm_name-nic" --os-disk-name "$site2_vm_name-os-disk" --size standard_b1s --generate-ssh-keys --tags $tag --no-wait
# Get site2 gw details
echo -e "\e[1;36m Getting $site2_gw_name details\e[0m"
site2_gw_vm_id=$(az vm show -n $site2_gw_name -g $site2_rg_name --query 'id' -o tsv)
wait_until_finished $site2_gw_vm_id
site2_gw_nic_id=$(az vm show -n $site2_gw_name -g $site2_rg_name --query 'networkProfile.networkInterfaces[0].id' -o tsv)
site2_gw_pip=$(az network public-ip show -n "$site2_gw_name-pubip" -g $site2_rg_name --query ipAddress -o tsv) && echo $site2_gw_pip
site2_gw_private_ip=$(az network nic show --ids $site2_gw_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo $site2_gw_private_ip

echo -e "\e[1;36m Deploying Local Network Gateways\e[0m"
# site1 local network gateway
az network local-gateway create --gateway-ip-address $site1_gw_pip -n $site1_gw_name -g $cloud_rg_name --local-address-prefixes "$site1_gw_private_ip/32" --asn $site1_gw_asn --bgp-peering-address $site1_gw_private_ip --tags $tag --no-wait

# site2 local network gateway
az network local-gateway create --gateway-ip-address $site2_gw_pip -n $site2_gw_name -g $cloud_rg_name --local-address-prefixes "$site2_gw_private_ip/32" --asn $site2_gw_asn --bgp-peering-address $site2_gw_private_ip --tags $tag --no-wait

echo -e "\e[1;36m Deploying on-premises routing tables\e[0m"
# site1 route table
az network route-table create -n site1-routing -g $site1_rg_name --tags $tag
az network route-table route create --address-prefix $cloud_vnet_address -n to-cloud -g $site1_rg_name --next-hop-type virtualappliance --route-table-name site1-routing --next-hop-ip-address $site1_gw_private_ip
az network route-table route create --address-prefix $site2_vnet_address -n to-site2 -g $site1_rg_name --next-hop-type virtualappliance --route-table-name site1-routing --next-hop-ip-address $site1_gw_private_ip
az network vnet subnet update --vnet-name $site1_vnet_name -n $site1_lan_subnet_name --route-table site1-routing -g $site1_rg_name

# site2 route table
az network route-table create -n site2-routing -g $site2_rg_name --tags $tag
az network route-table route create --address-prefix $cloud_vnet_address -n to-cloud -g $site2_rg_name --next-hop-type virtualappliance --route-table-name site2-routing --next-hop-ip-address $site2_gw_private_ip
az network route-table route create --address-prefix $site1_vnet_address -n to-site1 -g $site2_rg_name --next-hop-type virtualappliance --route-table-name site2-routing --next-hop-ip-address $site2_gw_private_ip
az network vnet subnet update --vnet-name $site2_vnet_name -n $site2_lan_subnet_name --route-table site2-routing -g $site2_rg_name

# Wait for Azure VPN GW to finish
cloud_vpngw_id=$(az network vnet-gateway show -n $cloud_gw_name -g $cloud_rg_name --query 'id' -o tsv)
wait_until_finished $cloud_vpngw_id

echo -e "\e[1;36m Deploying VPN Connections from VPN Gateway to on-premises sites\e[0m"
# s2s vpn connection with site1
az network vpn-connection create -n cloud-s2s-bgp-site1 -g $cloud_rg_name --vnet-gateway1 $cloud_gw_name --shared-key $psksecret --local-gateway2 $site1_gw_name --enable-bgp --tags $tag
# s2s vpn connection with site2
az network vpn-connection create -n cloud-s2s-bgp-site2 -g $cloud_rg_name --vnet-gateway1 $cloud_gw_name --shared-key $psksecret --local-gateway2 $site2_gw_name --enable-bgp --tags $tag

# get azure vpn gw details
vpngw_pip_0=$(az network vnet-gateway show -n $cloud_gw_name -g $cloud_rg_name --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv) && echo $vpngw_pip_0
vpngw_bgp_address=$(az network vnet-gateway show -n $cloud_gw_name -g $cloud_rg_name --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses' -o tsv) && echo $vpngw_bgp_address

###### site1 gw configuration #########
echo -e "\e[1;36m Copying confiuration files to $site1_gw_name\e[0m"
# ipsec.secrets
psk_file=/tmp/ipsec.secrets
cat <<EOF > $psk_file
$site1_gw_pip $vpngw_pip_0 : PSK $psksecret
EOF

# ipsec.conf
ipsec_file=/tmp/ipsec.conf
cat <<EOF > $ipsec_file
conn %default
         # Authentication Method : Pre-Shared Key
         leftauth=psk
         rightauth=psk
         ike=aes256-sha1-modp1024!
         ikelifetime=28800s
         # Phase 1 Negotiation Mode : main
         aggressive=no
         esp=aes256-sha1!
         lifetime=3600s
         keylife=3600s
         type=tunnel
         dpddelay=10s
         dpdtimeout=30s
         keyexchange=ikev2
         rekey=yes
         reauth=no
         dpdaction=restart
         closeaction=restart
         leftsubnet=0.0.0.0/0,::/0
         rightsubnet=0.0.0.0/0,::/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         installpolicy=yes
         compress=no
         mobike=no
conn Azure1
         # OnPrem Gateway Private IP Address :
         left=$site1_gw_private_ip
         # OnPrem Gateway Public IP Address :
         leftid=$site1_gw_pip
         # Azure VPN Gateway Public IP address :
         right=$vpngw_pip_0
         rightid=$vpngw_pip_0
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
EOF

# ipsec-vti.sh
ipsec_vti_file=/tmp/ipsec-vti.sh
tee -a $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash

#
# /etc/strongswan.d/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)
PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })
case "$PLUTO_CONNECTION" in
  Azure1)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$site1_gw_vti_address/32
    VTI_REMOTEADDR=$vpngw_bgp_address/32
    ;;
esac
case "${PLUTO_VERB}" in
    up-client)
        $IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
        $IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
        $IP link set ${VTI_INTERFACE} up mtu 1350
        $IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        $IP route flush table 220
        ;;
    down-client)
        $IP link del ${VTI_INTERFACE}
        $IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
EOT

sed -i "/\$site1_gw_vti_address/ s//$site1_gw_vti_address/" $ipsec_vti_file
sed -i "/\$vpngw_bgp_address/ s//$vpngw_bgp_address/" $ipsec_vti_file

# bgpd.conf
bgpd_conf_file=/tmp/bgpd.conf
cat <<EOF > $bgpd_conf_file
!
! Zebra configuration saved from vty
!   2021/10/06 05:42:41
!
hostname bgpd
password zebra
log stdout
!
router bgp $site1_gw_asn
 bgp router-id $site1_gw_private_ip
 network $site1_vnet_address
 neighbor $vpngw_bgp_address remote-as $cloud_gw_asn
 neighbor $vpngw_bgp_address soft-reconfiguration inbound
!
 address-family ipv6
 exit-address-family
 exit
!
line vty
!
EOF

# Copy files to site1 gw and restart ipsec daemon
username=$(whoami)
scp $psk_file $ipsec_file $ipsec_vti_file $bgpd_conf_file $site1_gw_pip:/home/$username
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site1_gw_pip "sudo mv /home/$username/ipsec.* /etc/ && sudo mv /home/$username/ipsec-vti.sh /etc/strongswan.d/ && chmod +x /etc/strongswan.d/ipsec-vti.sh &&  sudo mv /home/$username/bgpd.conf /etc/quagga/ && sudo service bgpd restart && sudo systemctl restart ipsec"

# deleting files from local session
rm $psk_file && rm $ipsec_file && rm $ipsec_vti_file && rm $bgpd_conf_file
###### End of site1 gw configuration


###### site2 gw configuration ##########
echo -e "\e[1;36m Copying confiuration files to $site2_gw_name\e[0m"
# ipsec.secrets
psk_file=/tmp/ipsec.secrets
cat <<EOF > $psk_file
$site2_gw_pip $vpngw_pip_0 : PSK $psksecret
EOF

# ipsec.conf
ipsec_file=/tmp/ipsec.conf
cat <<EOF > $ipsec_file
conn %default
         # authentication method : pre-shared key
         leftauth=psk
         rightauth=psk
         ike=aes256-sha1-modp1024!
         ikelifetime=28800s
         # phase 1 negotiation mode : main
         aggressive=no
         esp=aes256-sha1!
         lifetime=3600s
         keylife=3600s
         type=tunnel
         dpddelay=10s
         dpdtimeout=30s
         keyexchange=ikev2
         rekey=yes
         reauth=no
         dpdaction=restart
         closeaction=restart
         leftsubnet=0.0.0.0/0,::/0
         rightsubnet=0.0.0.0/0,::/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         installpolicy=yes
         compress=no
         mobike=no
conn Azure1
         # onprem gateway private ip address :
         left=$site2_gw_private_ip
         # onprem gateway public ip address :
         leftid=$site2_gw_pip
         # azure vpn gateway public ip address :
         right=$vpngw_pip_0
         rightid=$vpngw_pip_0
         auto=start
         # unique number per ipsec tunnel eg. 100, 101 etc
         mark=101
EOF

# ipsec-vti.sh
ipsec_vti_file=/tmp/ipsec-vti.sh
tee -a $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash

#
# /etc/strongswan.d/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)
PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })
case "$PLUTO_CONNECTION" in
  Azure1)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$site2_gw_vti_address/32
    VTI_REMOTEADDR=$vpngw_bgp_address/32
    ;;
esac
case "${PLUTO_VERB}" in
    up-client)
        $IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
        $IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
        $IP link set ${VTI_INTERFACE} up mtu 1350
        $IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        $IP route flush table 220
        ;;
    down-client)
        $IP link del ${VTI_INTERFACE}
        $IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
EOT

sed -i "/\$site2_gw_vti_address/ s//$site2_gw_vti_address/" $ipsec_vti_file
sed -i "/\$vpngw_bgp_address/ s//$vpngw_bgp_address/" $ipsec_vti_file

# bgpd.conf
bgpd_conf_file=/tmp/bgpd.conf
cat <<EOF > $bgpd_conf_file
!
! Zebra configuration saved from vty
!   2021/10/06 05:42:41
!
hostname bgpd
password zebra
log stdout
!
router bgp $site2_gw_asn
 bgp router-id $site2_gw_private_ip
 network $site2_vnet_address
 neighbor $vpngw_bgp_address remote-as $cloud_gw_asn
 neighbor $vpngw_bgp_address soft-reconfiguration inbound
!
 address-family ipv6
 exit-address-family
 exit
!
line vty
!
EOF

# Copy files to site2 gw and restart ipsec daemon
username=$(whoami)
scp $psk_file $ipsec_file $ipsec_vti_file $bgpd_conf_file $site2_gw_pip:/home/$username
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pip "sudo mv /home/$username/ipsec.* /etc/ && sudo mv /home/$username/ipsec-vti.sh /etc/strongswan.d/ && chmod +x /etc/strongswan.d/ipsec-vti.sh &&  sudo mv /home/$username/bgpd.conf /etc/quagga/ && sudo service bgpd restart && sudo systemctl restart ipsec"
# deleting files from local session
rm $psk_file && rm $ipsec_file && rm $ipsec_vti_file && rm $bgpd_conf_file
###### End of site2 gw configuration

# Checking VPN tunnel and BGP status
echo -e "\e[1;36m Checking VPN tunnel and BGP status on $site1_gw_name and $site2_gw_name\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site1_gw_pip "sudo ipsec status && sudo vtysh -c 'show ip route bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pip "sudo ipsec status && sudo vtysh -c 'show ip route bgp'"


## Clean up ##
#az group delete -n $cloud_rg_name --no-wait --yes
#az group delete -n $site1_rg_name --no-wait --yes
#az group delete -n $site2_rg_name --no-wait --yes
#rm $site_gw_cloudinit_file
