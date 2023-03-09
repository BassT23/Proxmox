## SSH Key-Based Authentication

### 1.
create one file per VM in `/root/Proxmox-Updater/VMs/<ID>` with content:

`IP="111.111.111.111"`   # use the IP from the VM!

IP can be found in Proxmox GUI (VM -> Overview)

### 2.
Configure SSH Key-Based Authentication from Host, who hosted the VM to root user in the VM

(Example for Debian Based Systems)

IN VM:
- install ssh server
`sudo apt install openssh-server`

- Set root password if not made:
`sudo passwd root`

- Edit the sshd_config file in `/etc/ssh/sshd_config`

`sudo nano /etc/ssh/sshd_config`

- Add a line in the Authentication section of the file that says `PermitRootLogin yes`. This line may already exist and be commented out with a "#". In this case, remove the "#"
```
# Authentication:
#LoginGraceTime 2m
PermitRootLogin yes
#StrictModes yes
```

- Save the updated `/etc/ssh/sshd_config` file

- Restart the SSH server
`sudo service sshd restart`

IN HOST which hosted VM:
- Copy key like:
`ssh-copy-id -i ~/<path-to-file>/id_rsa.pub root@<VM-ID>`
