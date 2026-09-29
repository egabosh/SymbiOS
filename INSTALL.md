# Installing SymbiOS

SymbiOS turns one Debian machine into a small server that you manage from a
web interface: users, services, backups, updates, firewall and monitoring.

There are two ways to install it. Pick the one that matches your hardware.

| Your hardware | Section |
|---|---|
| Raspberry Pi 4 or 5 | [Raspberry Pi](#raspberry-pi) |
| Anything else running Debian | [Debian](#debian) |

Both ways end the same way: you open a web page in your browser and follow a
setup guide there.

## Raspberry Pi

### 1. Download the image

Go to the releases page and download the most recent image file
(`.img.xz`):

<https://github.com/egabosh/SymbiOS/releases>

### 2. Write the image to the SD card

Use Raspberry Pi Imager:

- select your Pi model
- choose "Use OS" -> "Custom OS" and pick the downloaded `.img.xz`
- select your SD card and click "Write"

**Warning:** this erases everything on the SD card.

### 3. Start the Pi

Insert the SD card, connect the Pi to your network with an Ethernet cable and
power it on. A desktop appears on the attached screen.

### 4. Wait for the installation

The installation starts by itself on the first boot. You do not have to do
anything, and you do not have to run anything by hand.

It installs a lot of software, so it takes a while. The machine reboots once at
the end, and the desktop comes back. **That reboot is normal, not a fault.**

To watch what is happening, open a terminal on the desktop and follow the log:

```bash
# Prints the installation log of the first boot, and keeps printing new lines
tail -f /var/log/symbios-boot.log
```

You can close the terminal at any time. The installation continues without it.

If a step fails, the machine reboots and tries again. It keeps doing this until
it succeeds, so you can simply leave it alone.

### 5. Continue at [First login](#first-login)

## Debian

### 1. Prepare the machine

Install a current Debian on the machine. A minimal installation without a
desktop is enough. Make sure you are logged in as `root`.

### 2. Download the installation script

```bash
# Downloads install.sh from the SymbiOS repository into the current directory
wget "https://raw.githubusercontent.com/egabosh/SymbiOS/refs/heads/main/install.sh" -O install.sh
```

### 3. Run the installation

```bash
# Installs everything and prints every step while it works
bash install.sh
```

The script installs Ansible and Git if they are missing, downloads the SymbiOS
repository, and then works through its configuration one step at a time. Each
step ends with `OK` or `FAILED`, and at the end you get a short summary.

If a step fails, the script leaves you at a root prompt so that you can look at
the problem. Type `exit` to leave that prompt, fix the cause, and start
`bash install.sh` again. This is safe: the steps are written to be repeatable,
so work that is already finished is simply confirmed again.

### 4. Continue at [First login](#first-login)

## First login

### 1. Find the address of the machine

On the desktop, or in a terminal:

```bash
# Prints the IP addresses of this machine
hostname -I
```

### 2. Open the web interface

In a browser on any machine in the same network:

```
http://<the-ip-address>:8080/
```

On the Raspberry Pi desktop there is also a **SymbiOS WebUI** entry in the
application menu. It opens the same page, directly on the machine.

### 3. Log in

- user: `admin`
- password: `admin`

The web interface asks you for a new password right away, because this account
can control the whole machine. Choose a strong one and remember it.

### 4. Follow the setup guide

Open `/setup/`. It walks you through the rest of the configuration, in order:

1. **Server connection type** - whether the machine sits behind a home router,
   has its own public IP address, or is not connected to the internet at all.
   Your choice here decides which of the later steps you actually need.
2. **Language, timezone and keyboard**
3. **Set up a name (DNS)** - the address under which you will reach the server
4. **Make the server reachable from the internet** - only needed for the
   option "home connection" from step 1. A machine with its own public IP
   address does not need it, and neither does one that stays in the intranet.
5. **Create users**

Steps that are already finished are marked as such, so you can see at a glance
what is still open.

## Good to know

- **Port 8080 only works inside your own network.** The firewall opens it for
  private addresses only, so the web interface cannot be reached from the
  internet. That is on purpose.
- **HTTPS and two-factor login come later.** They need a name for the server,
  so they are set up once you have completed step 3 of the setup guide. Until
  then the web interface uses plain HTTP within your network.
- **The name must really point to your machine.** A domain you do not own will
  not work. The setup guide checks this for you and tells you if it does not
  match.
- **Backups start out local.** Until you enter a backup server under
  Settings -> Backup, snapshots are written to the machine itself. That protects
  you against mistakes, but not against a defect of the machine or the disk.
- **If something looks wrong**, the web interface has a **Logs** page that shows
  what the system is doing. During the installation itself, the log is
  `/var/log/symbios-boot.log` on the Raspberry Pi.
