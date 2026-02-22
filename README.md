# GRE over IPSec Tunnel

A hardened Bash-based installer for building and operating a GRE tunnel protected by IPSec (strongSwan).

## English

### Overview
This project automates setup and lifecycle management for a GRE tunnel running over IPSec.
It includes:
- Interactive setup menu
- Input validation for IPs and PSK
- Secure config handling (no `source` on config)
- Pinned and checksum-verified external script downloads (`bbr.sh`, `tcp.sh`)
- Dedicated systemd service with direct `socat` supervision
- Safer uninstall flow that removes only tunnel-specific IPSec files

### Requirements
- Debian/Ubuntu-like Linux (uses `apt-get`)
- Root access
- Packages: `curl`, `socat`, `strongswan`, `strongswan-pki`

### Quick Start
```bash
sudo bash tunnel.sh
```

### Menu Functions
1. Configure Tunnel
2. Check Remote Connection
3. Install `bbr.sh` and `tcp.sh` (pinned + SHA256 verified)
4. Check Tunnel Status
5. Remove Tunnel
6. Exit

### Files Managed
- `/etc/fou_tunnel_config`
- `/etc/ipsec.d/fou-tunnel.conf`
- `/etc/ipsec.d/fou-tunnel.secrets`
- `/etc/systemd/system/fou-tunnel.service`
- `/usr/local/sbin/fou-tunnel-runner.sh`

### Security Notes
- External helper scripts are downloaded from pinned commit URLs and verified with SHA256.
- IPSec PSK is read in silent mode and stored with restricted permissions.
- Firewall rules are intentionally not modified by this script.

---

## فارسی

### معرفی
این پروژه یک اسکریپت Bash سخت‌گیرانه‌تر برای راه‌اندازی و مدیریت تونل GRE روی IPSec (با strongSwan) است.

امکانات اصلی:
- منوی تعاملی برای نصب و مدیریت
- اعتبارسنجی ورودی‌ها (IP و PSK)
- مدیریت امن کانفیگ (بدون `source` روی فایل کانفیگ)
- دانلود اسکریپت‌های کمکی با لینک commit ثابت و بررسی SHA256
- سرویس systemd با مدیریت مستقیم `socat`
- حذف امن که فقط فایل‌های مربوط به همین تونل را پاک می‌کند

### پیش‌نیازها
- لینوکس Debian/Ubuntu (به دلیل `apt-get`)
- دسترسی root
- پکیج‌ها: `curl`، `socat`، `strongswan`، `strongswan-pki`

### اجرا
```bash
sudo bash tunnel.sh
```

### گزینه‌های منو
1. تنظیم تونل
2. بررسی ارتباط IP سمت مقابل
3. نصب `bbr.sh` و `tcp.sh` (با بررسی صحت فایل)
4. بررسی وضعیت تونل
5. حذف تونل
6. خروج

### فایل‌هایی که مدیریت می‌شوند
- `/etc/fou_tunnel_config`
- `/etc/ipsec.d/fou-tunnel.conf`
- `/etc/ipsec.d/fou-tunnel.secrets`
- `/etc/systemd/system/fou-tunnel.service`
- `/usr/local/sbin/fou-tunnel-runner.sh`

### نکات امنیتی
- اسکریپت‌های خارجی با URL ثابت (commit-pinned) دانلود و با SHA256 اعتبارسنجی می‌شوند.
- PSK به‌صورت مخفی دریافت و با دسترسی محدود ذخیره می‌شود.
- این اسکریپت قوانین فایروال را تغییر نمی‌دهد.
