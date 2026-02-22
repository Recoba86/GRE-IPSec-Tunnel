# Changelog

All notable changes to this project are documented in this file.

## [1.1.0] - 2026-02-22

### English
#### Added
- Commit-pinned URLs and SHA256 verification for downloaded helper scripts.
- Direct systemd supervision for `socat` (`Type=simple`, `Restart=always`).

#### Changed
- Runner script responsibilities narrowed to GRE lifecycle only.
- Service flow uses `ExecStartPre`/`ExecStopPost` for cleaner tunnel bring-up/tear-down.

### فارسی
#### اضافه شد
- لینک‌های ثابت بر اساس commit و اعتبارسنجی SHA256 برای اسکریپت‌های کمکی.
- مدیریت مستقیم `socat` توسط systemd با `Restart=always`.

#### تغییر کرد
- مسئولیت اسکریپت runner فقط به چرخه GRE محدود شد.
- جریان سرویس با `ExecStartPre` و `ExecStopPost` تمیزتر شد.

---

## [1.0.0] - 2026-02-22

### English
#### Added
- Hardened tunnel installer with validated input handling.
- Safer config loading without `source`.
- IPSec modernization (IKEv2, stronger proposals).
- Tunnel-specific IPSec file management to avoid destructive global deletion.
- Bilingual documentation.

#### Removed
- Firewall rule manipulation from setup and removal workflows.

### فارسی
#### اضافه شد
- نصب‌کننده‌ی سخت‌گیرانه‌تر تونل با اعتبارسنجی ورودی‌ها.
- بارگذاری امن کانفیگ بدون `source`.
- به‌روزرسانی تنظیمات IPSec با پروفایل مدرن‌تر.
- مدیریت فایل‌های اختصاصی IPSec برای جلوگیری از حذف مخرب تنظیمات سراسری.
- مستندات دوزبانه.

#### حذف شد
- دستکاری قوانین فایروال از روند نصب و حذف.
