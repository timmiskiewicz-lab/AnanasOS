# AnanasOS 1.0

Prosty system na bazie Ubuntu 24.04 LTS, na komputery 64-bitowe (Intel i AMD). Ma pulpit, ekran logowania, eksplorator plików, terminal, Firefoksa i obsługę AppImage. Da się go uruchomić z pendrive'a i zainstalować na dysku.

AnanasOS nie jest powiązany z Canonical. Ubuntu jest znakiem towarowym Canonical Ltd.

## Sesja live

Po starcie z pendrive'a system pokazuje ekran logowania.

- użytkownik: `ananas`
- hasło: `ananas`

Te dane są też na dole ekranu logowania. Na pulpicie jest ikona **Zainstaluj AnanasOS**.

## Instalacja na dysku

1. Zaloguj się w sesji live.
2. Otwórz **Zainstaluj AnanasOS**.
3. Wybierz dysk, język i swoje konto.
4. Po restarcie wyjmij pendrive i zaloguj się na konto utworzone w instalatorze.

Instalator kasuje wybrany dysk, gdy zostawisz opcję wymazania dysku. Przed instalacją skopiuj z niego ważne pliki.

## Pendrive

Obraz nazywa się `AnanasOS-1.0-amd64.iso`. Wgrywa się go programem, który robi kopię 1:1:

- balenaEtcher, albo
- Rufus w trybie **DD**

Zwykłe skopiowanie pliku ISO na pendrive nie wystarczy. Komputer musi startować z USB. Na nowszych płytach głównych działa start UEFI, także z Secure Boot (obraz używa podpisanego startu Ubuntu). Gdy płyta nie chce wystartować, wyłącz Secure Boot w ustawieniach firmware.

## Co jest w środku

- pulpit XFCE, ciemny motyw i tapeta z logo
- ekran logowania LightDM
- przy starcie logo ananasa i napis AnanasOS w żółtym gradiencie
- Thunar (pliki), terminal, edytor Mousepad
- Firefox
- AppImage: dwuklik albo „Uruchom AppImage” w menu pliku. Potrzebne biblioteki fuse są już w systemie
- instalator Calamares
- sieć, dźwięk, dyski Windows (NTFS), firmware kart Intela
- język polski i angielski. Sesja live startuje po polsku

Dodatkowe programy instaluje się w terminalu przez `sudo apt update` i `sudo apt install nazwa`.

SSH jest zainstalowane, ale po instalacji na dysku jest wyłączone. Włącza się je poleceniem `sudo systemctl enable --now ssh`. W sesji live SSH startuje samo, hasło jest takie jak do logowania.

## Złożenie obrazu od nowa

Potrzebny jest Ubuntu 24.04 (albo WSL2 z tą wersją) i około 25 GB wolnego miejsca na dysku linuksowym, nie na OneDrive.

```bash
sudo bash build/build-iso.sh
```

Gotowy plik ląduje w `C:\Users\miski\AnanasOS-iso\` gdy budowa idzie z WSL, albo w katalogu roboczym. Obraz ISO nie wchodzi do gita (GitHub przyjmuje w repozytorium pliki do 100 MB). Wersja do pobrania jest w Release tego repozytorium.
