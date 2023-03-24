# SSH Key-Based Authentication

## VM need an static IP Address - Random IP will not work with the script.

### IN VM:
(Example for Debian Based Systems)

- install ssh server (if not installed):
`sudo apt-get install openssh-server`

- Set root password (if not made):
`sudo passwd root`

- Edit the sshd_config file in `/etc/ssh/sshd_config`:

`sudo nano /etc/ssh/sshd_config`

- Add a line in the Authentication section of the file that says `PermitRootLogin yes`. This line may already exist and be commented out with a "#". In this case, remove the "#":
```
# Authentication:
#LoginGraceTime 2m
PermitRootLogin yes
#StrictModes yes
```

- Save the updated `/etc/ssh/sshd_config` file

- Restart the SSH server:
`sudo service sshd restart`


### IN HOST:
- create one file per VM in `/root/Proxmox-Updater/VMs/<ID>` with content:

`IP="111.111.111.111"`   # use the IP from the VM!

(IP can be found in VM with command: `hostname -I`)

- Copy ssh key to VM:
`ssh-copy-id -i /root/.ssh/id_rsa.pub root@<VM-IP>`
