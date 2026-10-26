# Boot

Gabungkan **zip kernel AnyKernel3** + **boot.img stock** → **boot.img siap flash**, lewat GitHub Actions (bisa dijalankan dari HP).

Default untuk **POCO F4 GT (ingres)**, tapi bekerja untuk boot.img GKI apa pun.

## Default & otomatis

- **Zip kernel default:** zip **terbaru** (berdasarkan waktu upload) di release
  [`kingD2N/ALL-PROJECT-D2N` → `HyperOS_4`](https://github.com/kingD2N/ALL-PROJECT-D2N/releases/tag/HyperOS_4).
- **boot.img stock default:** `boot.img` di release `stock` repo ini; kalau tidak ada,
  file `*boot*.img` / `*Boot*.img` di release `HyperOS_4`.
- **Otomatis:** workflow mengecek release `HyperOS_4` **tiap jam**. Begitu ada zip kernel baru,
  boot.img langsung dibuat dan dirilis dengan tag `auto-k<id zip>-b<id boot>`. Zip yang sama
  tidak dibuat ulang; ganti boot.img stock juga memicu build baru.
  Selama boot.img stock belum ada, auto-build dilewati (hanya peringatan, tidak gagal).

Ganti sumber otomatis di blok `env:` pada `.github/workflows/patch-boot.yml`
(`AUTO_KERNEL_ZIP`, `AUTO_BOOT_IMG`).

> GitHub menonaktifkan jadwal di repo publik setelah 60 hari tanpa commit — aktifkan lagi dari tab Actions bila itu terjadi.

## Cara pakai manual

1. **Siapkan boot.img stock** (pilih salah satu):
   - Buat release dengan tag `stock` di repo ini, lalu lampirkan `boot.img` (cara termudah dari HP; batas 2 GB).
   - Atau upload `boot.img` ke release `HyperOS_4` di ALL-PROJECT-D2N.
   - Atau pakai link langsung / Google Drive / zip ROM fastboot / zip ROM berisi `payload.bin`.
2. Buka tab **Actions → Patch Kernel Zip -> boot.img → Run workflow** (input sudah terisi default).
3. Ubah input bila perlu:

| Input | Contoh |
|---|---|
| `kernel_zip` | `release:kingD2N/ALL-PROJECT-D2N@HyperOS_4/*.zip` (default, ambil terbaru) |
| | `https://github.com/kingD2N/Kernel_NoMount_ingres/releases/download/v1/Melt-MIX.zip` |
| | `https://drive.google.com/file/d/xxxx/view` |
| `boot_img` | `release:stock/boot.img \|\| release:kingD2N/ALL-PROJECT-D2N@HyperOS_4/*[Bb]oot*.img` (default) |
| | `https://.../ingres_global_images_xxx.tgz` (ROM fastboot, `images/boot.img` diambil otomatis) |
| | `https://.../rom.zip` (ambil `boot.img` atau `payload.bin` di dalamnya) |
| `output_name` | kosong = `boot-<nama-zip>.img` |
| `magisk_version` | `latest` (sumber `magiskboot`) |
| `publish_release` | centang = hasil di-upload ke Releases |

4. Unduh hasilnya dari **Releases** (tag `boot-<nomor run>`) atau dari artifact run.
5. Flash: `fastboot flash boot boot-xxx.img` atau TWRP/OrangeFox → Install Image → Boot.

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
