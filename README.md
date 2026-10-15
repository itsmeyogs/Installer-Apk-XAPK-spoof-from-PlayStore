# Android APK/XAPK Installer

Installer Windows untuk memasang APK dan XAPK ke Android melalui ADB.

## Fitur

- Instal APK tunggal.
- Instal XAPK dengan banyak split APK.
- Deteksi file APK dan OBB secara rekursif di dalam XAPK.
- Deteksi package ID dari `aapt`/`aapt2` atau `manifest.json` XAPK.
- Instal melalui device package manager:
  ```text
  adb shell pm install -i com.android.vending
  ```
- Split APK memakai install session:
  ```text
  pm install-create
  pm install-write
  pm install-commit
  ```
- Push file `.obb` ke `/sdcard/Android/obb/<package-id>/`.
- Download Platform Tools resmi Google otomatis bila ADB lokal belum ada.
- Memilih device secara interaktif jika lebih dari satu device terhubung.
- Merestart ADB server sebelum membaca daftar device untuk membersihkan status stale.
- Menangani output progress ADB tanpa menampilkannya sebagai error PowerShell.
- Hapus file temporary setelah proses selesai.

## Struktur

```text
install.bat
install.ps1
tools\
  platform-tools\       ADB cache
  platform-tools-latest-windows.zip
```

## Persyaratan

- Windows 10/11.
- Android USB debugging aktif.
- Device sudah terhubung melalui USB.
- RSA debugging prompt sudah disetujui di device.
- Ruang penyimpanan cukup di PC dan device.

Root tidak wajib untuk semua device. Namun beberapa ROM membatasi `pm install -i` untuk shell biasa. Script ini tidak menjalankan `su`; jika terjadi `INSTALL_FAILED` atau installer tetap terbaca sebagai `system`, pembatasan ROM harus ditangani di device secara terpisah.

## Penggunaan CMD

Buka Command Prompt pada folder installer.

APK:

```cmd
install.bat "app-release.apk"
```

XAPK:

```cmd
install.bat "PUBGM_FLASH.xapk"
```

Dengan serial device:

```cmd
install.bat "app-release.apk" 5fbfa0cb
install.bat "PUBGM_FLASH.xapk" 5fbfa0cb
```

Path dengan spasi harus diapit tanda kutip:

```cmd
install.bat "C:\Users\Public\Downloads\my app.xapk" 5fbfa0cb
```

Jika lebih dari satu device aktif dan serial tidak diberikan, installer menampilkan daftar device dan meminta pilihan berdasarkan nomor.
Sebelum proses push, installer menampilkan nama device, serial, dan path ADB yang dipakai sebagai target instalasi.

## Penggunaan PowerShell

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" ".\app-release.apk"
```

Dengan serial:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" ".\PUBGM_FLASH.xapk" "5fbfa0cb"
```

`install.bat` memanggil PowerShell otomatis. CMD tetap dapat dipakai sebagai command shell utama.

## Cek Device

Jika serial belum diketahui:

```cmd
tools\platform-tools\adb.exe devices -l
```

Installer menjalankan `adb kill-server` lalu `adb start-server` sebelum membaca device. Jika dialog RSA muncul kembali di device, buka kunci device dan tekan **Allow**.
Installer mencari ADB dengan urutan `tools\platform-tools\adb.exe`, `adb.exe` di folder script, lalu `adb.exe` yang tersedia di `PATH`. Jangan menjalankan beberapa versi ADB secara bersamaan karena versi client/server berbeda dapat menghasilkan pesan `adb server version ... doesn't match this client`.

Output device yang siap dipakai memiliki status `device`:

```text
5fbfa0cb    device    product:beryllium model:POCO_F1
```

Status berikut ditolak:

- `unauthorized`: terima RSA prompt di device.
- `offline`: cabut-pasang USB atau restart ADB.
- `bootloader`: reboot device ke Android normal.
- Tidak ada device: aktifkan USB debugging dan periksa kabel/driver.

Jika terdapat beberapa device dengan status `device`, installer menampilkan menu pilihan. Gunakan serial sebagai argumen kedua untuk melewati menu:

```cmd
install.bat "PUBGM_FLASH.xapk" SERIAL_DEVICE
```

## Alur APK

1. Validasi file dan ekstensi `.apk`.
2. Cari package ID melalui `aapt`/`aapt2` jika tersedia. Jika tidak ditemukan, APK tetap diproses sebagai APK tunggal.
3. Push APK ke `/data/local/tmp/`.
4. Jalankan:
   ```text
    adb -s SERIAL_DEVICE shell pm install -i com.android.vending -r APK_PATH
   ```
5. Hapus APK temporary dari device.

## Alur XAPK

1. Ekstrak XAPK ke folder temporary unik.
2. Lindungi ekstraksi dari ZIP path traversal.
3. Cari semua APK dan OBB secara rekursif.
4. Kelompokkan APK berdasarkan package ID. Parser `aapt`/`aapt2` diprioritaskan; fallback memakai field `package_name` dari `manifest.json`.
5. Push APK ke `/data/local/tmp/`.
6. Buat install session:
   ```text
    adb -s SERIAL_DEVICE shell pm install-create -i com.android.vending -r
   ```
7. Tulis setiap APK. Script menyertakan ukuran file melalui opsi `-S`:
   ```text
     adb -s SERIAL_DEVICE shell pm install-write -S APK_SIZE SESSION_ID INDEX APK_PATH
   ```
8. Commit session:
   ```text
    adb -s SERIAL_DEVICE shell pm install-commit SESSION_ID
   ```
9. Push OBB setelah semua APK berhasil dipasang.
10. Hapus file temporary.

Jika XAPK berisi beberapa package dan OBB tidak dapat dipetakan secara aman, proses dihentikan sebelum OBB disalin. Jika XAPK tidak memiliki `manifest.json` atau parser APK yang dapat menentukan package ID, proses dihentikan.

## Verifikasi Installer Source

Cari package ID aplikasi, lalu jalankan:

```cmd
tools\platform-tools\adb.exe -s SERIAL_DEVICE shell pm list packages -i | findstr PACKAGE_ID
```

Hasil yang diharapkan:

```text
package:com.example.app installer=com.android.vending
```

`com.android.vending` adalah package ID Google Play Store. Metadata installer bukan bukti bahwa APK diunduh atau diverifikasi oleh Google Play. Hasil ini hanya tersedia jika instalasi berhasil dan device mengizinkan metadata installer tersebut.

## Verifikasi OBB

```cmd
tools\platform-tools\adb.exe -s SERIAL_DEVICE shell ls -l /sdcard/Android/obb/PACKAGE_ID/
```

Nama file OBB dipertahankan. File non-OBB tidak disalin ke folder OBB.

## Auto-download ADB

Jika ADB tidak ditemukan di `tools\platform-tools\adb.exe`, folder script, atau `PATH`, script mengunduh Platform Tools resmi Google dari:

```text
https://dl.google.com/android/repository/platform-tools-latest-windows.zip
```

Arsip diekstrak ke:

```text
tools\platform-tools\
```

Dependency disimpan sebagai cache. Jika `tools\platform-tools\adb.exe` sudah ada, script tidak mengunduh ulang. File sumber APK/XAPK tidak diubah atau dihapus.

## Temporary Files

Script membersihkan:

- Folder ekstraksi XAPK di `%TEMP%\xapk-installer-<GUID>\`.
- APK temporary di `/data/local/tmp/`.
- Install session yang gagal sebelum commit.

Script tidak menghapus:

- APK/XAPK sumber.
- `tools\platform-tools\`.
- Cache ZIP Platform Tools.
- OBB yang sudah berhasil dikirim ke device.

## Error Umum

### `No authorized Android device found`

Aktifkan USB debugging, sambungkan ulang device, lalu setujui dialog RSA.

Installer otomatis me-restart ADB server. Jika status tetap `unauthorized`, cabut-pasang kabel USB, buka kunci device, lalu setujui dialog RSA.

### `More than one device is connected`

Tanpa serial, installer akan menampilkan daftar device aktif dan meminta pilihan angka. Untuk menjalankan tanpa prompt, gunakan serial device:

```cmd
install.bat "app.xapk" SERIAL
```

Lihat serial dengan:

```cmd
tools\platform-tools\adb.exe devices -l
```

### Output `NativeCommandError` saat `adb push`

Versi terbaru membaca output ADB melalui `System.Diagnostics.Process`. Progress `adb push` yang ditulis ke `stderr` tidak dianggap error. Hanya exit code ADB selain `0` yang menghentikan instalasi.

### Target device tidak sesuai daftar ADB lain

Periksa path ADB yang ditampilkan installer pada bagian `Installation target`. Jalankan perintah berikut menggunakan executable yang sama. Jika ADB tidak berada di `tools\platform-tools`, ganti path contoh dengan path yang ditampilkan:

```cmd
tools\platform-tools\adb.exe devices -l
```

### `XAPK contains no APK files`

Arsip XAPK tidak berisi file `.apk`.

### `Cannot determine package ID`

XAPK tidak memiliki package ID yang dapat dibaca dari `aapt`/`aapt2` atau `manifest.json`. Pastikan parser APK tersedia di Android SDK/PATH, atau gunakan `manifest.json` dengan field `package_name` yang valid.

### `INSTALL_FAILED`

Periksa kompatibilitas ABI, versi Android, signature APK, ruang penyimpanan, dan izin instalasi dari sumber tidak dikenal.

### Installer tetap `system`

ROM atau Android membatasi installer package untuk shell ADB. `pm install -i` dapat memerlukan root pada device tersebut. Root tidak dapat dibuat dari Windows installer.

## Exit Code

- `0`: instalasi berhasil.
- `1`: kegagalan ADB, device, instalasi, atau push OBB.
- `2`: parameter tidak valid atau file input tidak ditemukan.

## Lisensi

Script ini tidak menyertakan Platform Tools. Platform Tools diunduh dari distribusi resmi Google dan tunduk pada lisensinya masing-masing.
