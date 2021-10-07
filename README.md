# Azure-Site-to-Site-S2S-VPN-with-BGP
This a linux shell scripts that can be used to create an environment to simulate Azure S2S VPN with BGP
![diagram-s2s-bgp.png](/diagram-s2s-bgp.png)

# How to use it
1. Connect to [Azure Cloud Shell](https://shell.azure.com/).
2. Clone the repository by running the command below:
```
git clone https://github.com/wshamroukh/Azure-Site-to-Site-S2S-VPN-with-BGP
```
3. Edit the variables in `s2s_bgp.sh` to your needs and then save the changes.
4. Run the shell scrip simple by running the command:
```
cd Azure-Site-to-Site-S2S-VPN-with-BGP
chmod +x s2s_bgp.sh
./s2s_bgp.sh
```
5. You will be prompted to enter the password (which is a variable that can be changed in step#3) for the site1-gw and site2-gw VMs.
