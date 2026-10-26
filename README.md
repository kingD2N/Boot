# Boot

Gabungkan **zip kernel AnyKernel3** + **boot.img stock HyperOS resmi** → **boot.img kernel custom berbasis stock**, siap flash. Jalan di GitHub Actions (bisa dari HP), tanpa perlu upload boot.img sendiri.

Default untuk **POCO F4 GT (ingres)**, tapi skripnya bekerja untuk boot.img GKI apa pun.

## Default & otomatis

- **Zip kernel:** zip **terbaru** (berdasarkan waktu upload) di release
  [`kingD2N/ALL-PROJECT-D2N` → `HyperOS_4`](https://github.com/kingD2N/ALL-PROJECT-D2N/releases/tag/HyperOS_4).
- **boot.img stock:** diambil langsung dari **ROM recovery resmi Xiaomi HyperOS OS2.0.3.0**
  (versi terakhir; POCO F4 GT sudah EOL):

  | `stock_rom` | Versi | File ROM |
  |---|---|---|
  | `global` (default) | OS2.0.3.0.ULJMIXM | `ingres_global-ota_full-OS2.0.3.0.ULJMIXM-user-14.0-b7c6438dbb.zip` |
  | `indonesia` | OS2.0.3.0.ULJIDXM | `ingres_id_global-ota_full-OS2.0.3.0.ULJIDXM-user-14.0-4c53c72437.zip` |

  ROM-nya 5,4 GB, tapi **hanya partisi `boot` yang diunduh (~100 MB)** lewat HTTP Range
  (`scripts/ota_boot.py`), lalu diverifikasi SHA-256 terhadap manifest `payload.bin`.
  Mirror dicoba berurutan: `bigota.d.miui.com` → `cdnorg.d.miui.com` → mirror Aliyun SGP.
  Kalau semua mirror gagal: `boot.img` di release `stock` repo ini, lalu `*boot*.img` di `HyperOS_4`.
- **Otomatis:** workflow mengecek release `HyperOS_4` **tiap jam**. Begitu ada zip kernel baru,
  kernel custom langsung dibuat dan dirilis (tag `auto-k<id zip>-b<id boot>`). Zip yang sama
  tidak dibuat ulang.

Ganti sumber otomatis di blok `env:` pada `.github/workflows/patch-boot.yml`
(`AUTO_KERNEL_ZIP`, `AUTO_STOCK_ROM`, `ROM_*`).

> GitHub menonaktifkan jadwal di repo publik setelah 60 hari tanpa commit — aktifkan lagi dari tab Actions bila itu terjadi.

## Cara pakai manual

1. Buka tab **Actions → Patch Kernel Zip -> boot.img → Run workflow**.
2. Pilih `stock_rom` (`global` / `indonesia`), sisanya biarkan default, lalu jalankan.
3. Unduh hasil dari **Releases**.

Input lain (opsional):

| Input | Contoh |
|---|---|
| `kernel_zip` | `release:kingD2N/ALL-PROJECT-D2N@HyperOS_4/*.zip` (default, ambil terbaru) |
| | `https://github.com/kingD2N/Kernel_NoMount_ingres/releases/download/v1/Melt-MIX.zip` |
| | `https://drive.google.com/file/d/xxxx/view` |
| `boot_img` | kosong = ROM resmi sesuai `stock_rom` (default). Isi untuk menimpa: |
| | `release:stock/boot.img` (boot.img yang kamu upload ke release `stock`) |
| | `https://.../ingres_global_images_xxx.tgz` (ROM fastboot, `images/boot.img` diambil otomatis) |
| | `https://.../rom.zip` (ambil `boot.img` atau `payload.bin` di dalamnya) |
| `output_name` | kosong = `boot-<nama-zip>-<versi stock>.img` |
| `magisk_version` | `latest` (sumber `magiskboot`) |
| `publish_release` | centang = hasil di-upload ke Releases |

Flash hasil: `fastboot flash boot boot-xxx.img` atau TWRP/OrangeFox → Install Image → Boot.
Pakai boot.img dari versi ROM yang **sama** dengan yang terpasang di HP (pilih `global`/`indonesia` sesuai ROM-mu).

## Format sumber yang didukung

```
https://...                    link langsung
https://drive.google.com/...   Google Drive (harus "siapa saja yang punya link")
release:TAG/POLA               asset release repo ini, mis. release:stock/boot.img
release:OWNER/REPO@TAG/POLA    asset release repo lain, TAG boleh "latest"
path/di/repo                   file di dalam repo
A || B                         coba A dulu, kalau tidak ada pakai B
```

Untuk sumber `release:`, bila beberapa asset cocok dengan POLA, yang dipakai adalah yang **paling baru diupload**.

## Cara kerja

`scripts/patch_boot.sh` meniru AnyKernel3: unpack boot.img stock dengan `magiskboot` (diambil dari APK Magisk resmi), ganti `kernel` dengan `Image`/`Image.gz`/`Image.lz4` dari zip, lalu repack. `magiskboot` otomatis mengompres kernel sesuai format stock dan mempertahankan footer AVB serta ukuran image. Hasil di-unpack ulang untuk memastikan kernel di dalamnya identik dengan isi zip.

**Yang tidak bisa masuk ke boot.img** (workflow memberi peringatan):
- `dtbo.img` → ikut di-upload terpisah, flash ke partisi `dtbo`.
- Modul `.ko` di `modules/` → AK3 memasangnya ke `/vendor` saat flash di recovery.
- Modifikasi `ramdisk/` / `patch/` dari `anykernel.sh` → tidak dijalankan.

Kalau zip kernel bergantung pada salah satu hal di atas, flash zip-nya lewat recovery saja.

## Jalankan manual (Linux)

```sh
MAGISKBOOT=./magiskboot ./scripts/patch_boot.sh kernel.zip boot.img out/
```
