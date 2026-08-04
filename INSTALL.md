# palimpsest — install checklist

Ordered. Do not skip ahead; a couple of steps exist specifically to avoid a
problem created by a later one.

Assumes: Alienware x17 R2, 2 TB NVMe as the only disk, wired ethernet, a NixOS
**26.05 minimal** ISO on a USB stick.

> Throughout, `/dev/nvme0n1` is assumed to be the NVMe. **Confirm with `lsblk`
> before running anything destructive.** Everything in §3 erases the disk.

---

## 1. BIOS — do this first

Power on, tap `F2`.

| Setting | Value | Why it matters |
|---|---|---|
| Graphics mode | **Hybrid / Optimus** | Discrete-only disables the iGPU and QuickSync disappears entirely. Non-negotiable. |
| AC power recovery | **On** | The box comes back by itself after an outage. |
| Battery charge configuration | **Primarily AC Use** | Charge ceiling that persists without Alienware's Windows software. |
| Secure Boot | **Off** | This config does not set up signed boot. |
| Wake on lid open / USB wake | **Off** | It is headless. |

Then boot the USB stick (`F12`).

---

## 2. Get a network and a root shell

```bash
sudo -i
ip a                      # confirm the wired interface has an address
ping -c2 cache.nixos.org
```

Wired should come up by DHCP on its own. If it did not, check the cable — do
not fall back to Wi-Fi, the installed system does not enable it.

Enable flakes for the installer session:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
```

---

## 3. Partition — DESTRUCTIVE

Three partitions: ESP, root, and the data volume.

```bash
lsblk                     # LOOK AT THIS. Confirm the target is /dev/nvme0n1.

parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP   fat32 1MiB   1GiB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart root  ext4  1GiB   101GiB
parted /dev/nvme0n1 -- mkpart data  ext4  101GiB 100%
```

Format. **The `-L palimpsest-data` label is required, not cosmetic** —
`modules/storage.nix` mounts `/data` by that label and nothing else.

```bash
mkfs.fat  -F 32 -n BOOT             /dev/nvme0n1p1
mkfs.ext4       -L nixos            /dev/nvme0n1p2
mkfs.ext4       -L palimpsest-data  /dev/nvme0n1p3
```

Verify the labels took:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL
```

---

## 4. Mount — and deliberately DO NOT mount /data

```bash
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/BOOT /mnt/boot
```

> **Do not mount `/data` under `/mnt`.** This step is what saves you a problem
> in §6.
>
> `nixos-generate-config` writes a `fileSystems` entry for every filesystem
> mounted at the time it runs. `/data` is already defined in
> `modules/storage.nix` (deliberately, so relocating it later is a one-line
> change), so a generated entry would collide and the build would fail with
> *"The option `fileSystems.\"/data\"` has conflicting definitions"*.
>
> Leaving it unmounted during install means the generated file contains only `/`
> and `/boot`, and there is nothing to clean up. `/data` mounts normally on the
> first real boot. It does not need to exist during installation.

---

## 5. Generate the hardware config

```bash
nixos-generate-config --root /mnt
```

This writes `/mnt/etc/nixos/hardware-configuration.nix`, detected from the real
machine. That file is the entire reason this step exists — everything else in
`/mnt/etc/nixos` is throwaway.

---

## 6. Put this repo in place and merge the hardware config

```bash
nix-shell -p git          # if git is not already present
mkdir -p /mnt/opt
git clone <your-remote>/palimpsest-system /mnt/opt/palimpsest-system
# (or copy it off a USB stick — however you carried it here)

cd /mnt/opt/palimpsest-system

# Replace the placeholder with the real thing.
cp /mnt/etc/nixos/hardware-configuration.nix \
   hosts/palimpsest/hardware-configuration.nix
```

Now **read** the file you just copied in:

```bash
cat hosts/palimpsest/hardware-configuration.nix
```

Check three things:

1. **No `fileSystems."/data"` block.** If §4 was followed there will not be one.
   If there is, delete it (and any `/data/transcode` block).
2. **`fileSystems."/"` and `fileSystems."/boot"` are present** and their UUIDs
   are real, not the `00000000-...` placeholders from the version in git.
3. **No `swapDevices` entry** pointing at a real device. We use zram; an empty
   `swapDevices = [ ];` is correct.

> **Flakes ignore untracked files.** This one surprises people. The copy above
> modifies a file that is already tracked in git, which is fine — but if you add
> any *new* file to this repo, `nix` will not see it until you `git add` it.
> A safe habit here:
>
> ```bash
> git add -A
> ```

---

## 7. Build before you install

Catch mistakes now, while a fix is a text edit rather than a reboot.

```bash
nixos-rebuild build --flake /mnt/opt/palimpsest-system#palimpsest
```

If this fails, fix it before continuing. The most likely error is the
`fileSystems."/data"` conflict described in §6 — see NOTES.md §2.1.

---

## 8. Install

```bash
nixos-install --flake /mnt/opt/palimpsest-system#palimpsest
```

It prompts for a **root password** at the end. That is the only credential
created during install, and it is the one you use for the first console login.
Choose something you can type on a laptop keyboard.

Then:

```bash
reboot
```

Remove the USB stick.

---

## 9. First boot — at the laptop's own keyboard

You need physical access for exactly this one step. SSH has password auth
disabled and `frank` has neither a password nor a key yet — by design, so that
no credential lives in git.

Log in as `root` with the password from §8:

```bash
passwd frank                       # set frank's password
ip a                               # note the LAN address
```

---

## 10. Get in over the network, then stop needing the console

From your workstation:

```bash
ssh-copy-id frank@<lan-ip>         # prompts for the password from §9
ssh frank@<lan-ip>                 # must now work WITHOUT a password prompt
```

Confirm key auth works **before** you put the laptop back on its shelf.

Optionally, make it declarative: add your public key to
`users.users.frank.openssh.authorizedKeys.keys` in `modules/users.nix` (a public
key is not a secret, so this does not violate contract §6) and rebuild.

---

## 11. Tailscale

```bash
sudo tailscale up --ssh
```

Follow the printed URL to authenticate. No auth key is in the config (contract
§6); this is a deliberate one-time manual step. The node key then persists in
`/var/lib/tailscale` across reboots and rebuilds.

Confirm from another tailnet device:

```bash
ssh frank@palimpsest
```

---

## 12. Router

Set a **DHCP reservation** for the wired interface's MAC.

**Do not port-forward anything.** Not 8096, not 22, not ever. Contract §5.

---

## 13. Verify the contract

```bash
sudo /opt/palimpsest-system/scripts/verify-contract
```

Everything must pass. This is the gate before the other half of the system gets
installed — it confirms UIDs, ownership, the firewall, the stack unit's state,
and most importantly that hardlinking works between `/data/torrents` and
`/data/media`.

Then confirm hardware transcoding specifically, since it is the one thing the
test VM could not check:

```bash
vainfo | grep -E 'VAProfile(H264|HEVC|VP9|AV1)'
```

Expect H264 and HEVC encode **and** decode, HEVC Main10, VP9 decode, AV1 decode.

And check whether the dGPU actually powered down (NOTES.md §3.1 — this one may
not pass, and it is not a blocker):

```bash
lspci -Dnn | grep -i nvidia
cat /sys/bus/pci/devices/0000:01:00.0/power_state    # want D3cold
```

---

## 14. Hand over to the stack

The system layer is done. `palimpsest-stack` gets cloned to
`/opt/palimpsest-stack` and owns `compose.yaml` from here.

The stack unit is installed but **will not start at boot yet** — that is
contract §3's "ships disabled". Bring it up by hand while debugging:

```bash
sudo systemctl start palimpsest-stack
journalctl -u palimpsest-stack -f
```

Once the stack genuinely works, make it permanent: set `enableAtBoot = true` in
`modules/containers.nix` and rebuild.

```bash
sudo nixos-rebuild switch --flake /opt/palimpsest-system#palimpsest
```

> `systemctl enable palimpsest-stack` does **not** persist on NixOS — the next
> rebuild reverts it. The flag in the file is the real switch.

---

## Rollback, any time

Every rebuild leaves the previous generation in the boot menu. If a change
breaks the machine, pick the previous entry at boot, or:

```bash
sudo nixos-rebuild switch --rollback
```
