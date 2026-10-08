# Kumo – Nonton Anime (Flutter)

Aplikasi streaming anime ringan berbasis Flutter. Metadata dari Jikan (MyAnimeList),
pemetaan ID lewat Kitsu, dan sumber streaming dari Torrentio.

## Build APK lewat GitHub Actions

1. Push seluruh isi folder ini ke repository GitHub (folder `.github` ikut ter-push).
2. Buka tab **Actions** di repository → pilih workflow **Build APK** → **Run workflow**
   (workflow juga jalan otomatis setiap push ke branch `main`).
3. Setelah selesai, unduh artifact **kumo-release-apk** dari halaman run tersebut.
   Di dalamnya ada `app-release.apk` yang siap dipasang di Android.

APK release ini ditandatangani dengan debug key bawaan template Flutter,
jadi bisa langsung dipasang untuk pemakaian pribadi/pengujian.

## Putar langsung dengan Real-Debrid

Agar episode bisa diputar langsung di dalam aplikasi (bukan magnet ke aplikasi
torrent eksternal):

1. Buat akun Real-Debrid, lalu ambil API key di <https://real-debrid.com/apitoken>.
2. Buka aplikasi Kumo → di Beranda ada kartu **Real-Debrid** → tempel API key →
   **Tes koneksi** → **Simpan**.
3. Cari anime, pilih episode, ketuk **Cari sumber**. Sumber berlabel `[RD+]`
   punya tautan putar dan akan diputar di player bawaan aplikasi.

API key hanya tersimpan di perangkat pengguna (SharedPreferences) dan hanya
dikirim ke Torrentio/Real-Debrid saat mencari/memutar sumber.

## Build lokal (opsional)

```bash
flutter pub get
flutter run            # mode debug
flutter build apk --release
```

## Catatan

- Izin `INTERNET` sudah ditambahkan di `android/app/src/main/AndroidManifest.xml`
  (template bawaan Flutter hanya menyertakannya untuk build debug/profile).
- Application ID bawaan masih `com.example.kumo`. Kalau mau diganti, ubah
  `applicationId` di `android/app/build.gradle.kts` sebelum rilis publik.
- Versi Flutter yang dipakai workflow: 3.35.5 (stable) — versi yang sama dengan
  yang dipakai memverifikasi proyek ini (`flutter analyze` bersih, build sukses).
