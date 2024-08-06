# zerotier
Zerotier docker and setup scripts

## Assumptions
Compose file assumes that the local ethernet interface is named eth0

## Join network
Go to zerotier web UI to copy the network id, from there go to the actual server and run the following:

```bash
docker exec zerotier zerotier-cli join <network_id>
```

Afterwards, go back to the web UI and authenticate the machine for that network id.

Finally, after the machine is authenticated restart the containers:

```bash
docker compose restart
```

And test whether it has been connected:

```bash
docker exec zerotier zerotier-cli status


200 info <hidden> 1.14.0 ONLINE
```

## Expose subnet
On the server run the following scripts and interactively choose the relevant options:

```bash
./iptables.sh
./iptables-save-apt-pkg-manager.sh
```

Example output of `iptables.sh`:

```bash
This script must be run as root. Trying to gain sudo privileges...
net.ipv4.ip_forward = 1
Available Ethernet interfaces:
[0] eth0
[1] ztm5trjudb
Please pick an interface for Zerotier (ZT_IFACE) by number from the list above:
ZT_IFACE index: 1
Please pick a physical interface for PHY_IFACE by number from the list above (default: eth0):
PHY_IFACE index (press Enter to use default):
Using ZT_IFACE: ztm5trjudb
Using PHY_IFACE: eth0
iptables rules set successfully.
IP address of ztm5trjudb: 172.30.2.159
IP address of eth0: 172.17.10.6
Subnet of eth0: 172.17.10.0/24
Now go to Zerotier web UI and make a route
172.17.10.0/24 via 172.30.2.159
```

Now remember to do what you are told by the script to expose the route in web UI, probably under General -> Managed Routes.

## IMPORTANT

After everything seems to be working, subnet and so forth, reboot the zerotier server host, and verify back again.

This verifies the iptables where saved.

## Troubleshooting

Try first by restarting clients, if not try reboot computer. 

If those won't work, dive in to it and google it.
