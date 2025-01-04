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


### IN HOST who hosted the VM:
- Copy ssh key to VM:
`ssh-copy-id -i /root/.ssh/id_rsa.pub root@<VM-IP>`
or, if used user is not root:
`ssh-copy-id -i /root/.ssh/id_rsa.pub <user>@<VM-IP>`


### IN HOST where ultimate-updater start:
- create one file per VM in `/etc/ultimate-updater/VMs/<ID>` with content:

```
IP="111.111.111.111"   # use the IP from the VM!
USER="root"
SSH_VM_PORT="22"
SSH_START_DELAY_TIME="45"
```
(IP can be found in VM with command: `hostname -I`)


## If user is NOT root, you need to prepare the user, to run admin commands - like `apt` - but user MUST be part of group `sudo`

Example for Ubuntu/Debian - with sudo (change in VM):

- `sudo visudo`
- add this to file:

`%sudo ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get upgrade -y, /usr/bin/apt-get --purge autoremove -y, /usr/bin/apt-get autoclean -y`
- save and exit file

Sources:
- easy, but unsafe -> look [here](https://askubuntu.com/questions/74054/run-apt-get-without-sudo)
- for more safety -> look [here](https://stackoverflow.com/questions/73397309/how-do-i-enable-passwordless-sudo-for-all-options-for-a-command):
