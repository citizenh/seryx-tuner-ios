# Seryx Tuner (iOS, private)

Petite app iPhone **privée** (jamais sur l'App Store) qui se connecte à ton **adaptateur OBD Bluetooth LE (ELM327)** et envoie les réglages upshift à ton ECU par trame CAN custom vers `0x7E0`.

- **Enable** (feat1), **Cylinders cut 1–4** (feat2), **Mode A/B** (feat3)
- **Apply** → envoie `01 A0 01 <en>`, `01 A0 02 <cut>`, `01 A0 03 <mode>`
- **Read back** → envoie `01 A1` et affiche la réponse ECU
- Le firmware écrit lui-même le magic + checksum ; l'app n'envoie que les trames 4 octets.

> Protocole : SET = `01 A0 <feat> <val>`, GET = `01 A1`. feat1=enable, feat2=cut(1-4), feat3=mode (A=1 / B=0). Pas de security access.

---

## Construire l'IPA SANS Mac (depuis Windows)

Tout se compile dans le cloud via **GitHub Actions** (macOS gratuit).

1. **Crée un repo GitHub privé** (ex. `seryx-tuner-ios`) et pousse ce dossier dedans :
   ```bash
   cd SeryxTuner-iOS
   git init && git add . && git commit -m "Seryx Tuner iOS"
   git branch -M main
   git remote add origin https://github.com/<ton-user>/seryx-tuner-ios.git
   git push -u origin main
   ```
2. Le workflow **Build unsigned IPA** se lance tout seul (onglet **Actions** du repo). Sinon, clique **Run workflow**.
3. Quand c'est vert : ouvre le run → section **Artifacts** → télécharge **`SeryxTuner-unsigned-ipa`** → dézippe pour obtenir `SeryxTuner-unsigned.ipa`.

L'IPA est **non signée** : on la signe avec ton Apple ID au moment de l'installation (étape suivante).

---

## Installer sur ton iPhone (Windows, gratuit)

Choisis **UNE** des deux méthodes. Les deux utilisent ton **Apple ID gratuit** (compte dev payant pas obligatoire).

### Option A — AltStore (recommandé : re-signe tout seul)
1. Installe **iTunes** + **iCloud** (versions depuis apple.com, pas celles du Microsoft Store).
2. Installe **AltServer** sur Windows : https://altstore.io
3. Branche l'iPhone en USB, confie-lui ton Apple ID, installe **AltStore** sur le téléphone.
4. Dans AltStore (sur l'iPhone) → **+** → choisis `SeryxTuner-unsigned.ipa`.
5. Réglages → Général → **VPN et gestion de l'appareil** → fais confiance à ton certificat.
6. AltStore **re-signe automatiquement tous les 7 jours** tant que le PC + AltServer tournent sur le même WiFi.

### Option B — Sideloadly (plus simple, re-signe à la main)
1. Installe **iTunes** + **iCloud** (depuis apple.com).
2. Installe **Sideloadly** : https://sideloadly.io
3. Branche l'iPhone, glisse `SeryxTuner-unsigned.ipa`, entre ton Apple ID, clique **Start**.
4. Réglages → Général → **VPN et gestion de l'appareil** → fais confiance.
5. Compte gratuit = l'app **expire après 7 jours** → re-fais l'étape 3 pour la réactiver (compte dev 99 $/an = valable 1 an).

> Un **mot de passe spécifique à l'app** Apple ID peut être demandé si tu as la double authentification : crée-le sur https://account.apple.com (Sécurité → Mots de passe pour app).

---

## Utilisation
1. Mets le contact (ECU alimenté), branche l'adaptateur BLE sur l'OBD.
2. Ouvre l'app → **Scan** → choisis ton adaptateur → **Connected**.
3. Règle Enable / Cut (1-4) / Mode, puis **APPLY TO ECU**.
4. **Read back** pour vérifier ce que l'ECU a reçu.
5. Onglet **Raw** pour envoyer une trame manuelle (ex. `01A00201`).

Si ton adaptateur n'apparaît pas ou ne répond pas, le **Log** en bas montre tout le dialogue ELM327 (TX/RX) — envoie-le moi et j'ajuste la séquence d'init ou les UUID BLE.

---

## Structure
```
Sources/SeryxTunerApp.swift   entrée SwiftUI
Sources/BLEManager.swift      CoreBluetooth + file de commandes ELM327
Sources/ContentView.swift     UI (connexion, config, log, raw)
project.yml                   projet XcodeGen (génère le .xcodeproj dans le CI)
.github/workflows/ios-build.yml   build macOS cloud → IPA non signée
```
