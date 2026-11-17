# SI Studio on the web – try it and share it

The same code builds the Android APK and the web app. On the web:
- Analyses are saved in the tester's own browser.
- Exports go to the Downloads folder.
- On a wide screen the app uses a side navigation bar.

---

## 1. Try it on your PC (5 minutes)

Run these in the project folder (`SI Quick Analysis - Claude`):

```powershell
flutter create --platforms=web .
flutter pub get
flutter run -d chrome
```

- `flutter create --platforms=web .` only adds web support to the project. It keeps the existing `web/` files (page, icons, manifest) and all your code; it only creates missing files.
- Chrome opens with SI Studio. Press `r` in the terminal to reload after code changes.
- Edge works too: `flutter run -d edge`.

---

## 2. Publish it for testers

Pick **one** of the two options.

| | Option A – GitHub Pages | Option B – Netlify Drop |
|---|---|---|
| Cost | Free | Free |
| Link | `https://<user>.github.io/<repo>/` | `https://<name>.netlify.app` |
| Source code | **Public** (free Pages needs a public repository) | Stays private – you upload only the built site |
| Updating | Automatic on every push | Build locally and drag the folder again |

### Option A – GitHub Pages (automatic builds)

The workflow `.github/workflows/deploy-web.yml` runs on every push to `main`. It runs the tests, builds the web app with Flutter 3.29.0 and publishes it.

This project already lives at **https://github.com/rinzlerz/SI-Analysis-Studio**, and the site is published at **https://rinzlerz.github.io/SI-Analysis-Studio/**. To set up a fresh copy elsewhere:

1. Create a free account at github.com, then a **new public repository**, for example `si-studio`. Do not add a README, so the repository starts empty.
2. Upload the project. Use **either** GitHub Desktop (*File → Add local repository* → choose the project folder → *Publish repository*), **or** these commands:
   ```powershell
   git init
   git add .
   git commit -m "SI Studio"
   git branch -M main
   git remote add origin https://github.com/<user>/si-studio.git
   git push -u origin main
   ```
   The existing `.gitignore` already keeps `build/` and `.dart_tool/` out of the repository.
3. In the repository, open **Settings → Pages**. Under *Build and deployment → Source*, choose **GitHub Actions**.
4. Open the **Actions** tab. The *Deploy web app* run takes about 3–5 minutes. When it is green, the link appears in the run summary: `https://<user>.github.io/si-studio/`.
5. To update, push again. Testers get the new version the next time they open or reload the page.

### Option B – Netlify Drop (no repository needed)

1. Build the site:
   ```powershell
   flutter build web --release
   ```
2. Open https://app.netlify.com/drop, sign in, and drag the **`build\web`** folder onto the page.
3. Netlify gives you a link straight away. In *Site configuration* you can rename it, for example `si-studio.netlify.app`.
4. To update, build again and drag the folder onto the site's *Deploys* page.

---

## 3. Before you send the link

- **Feedback link:** in `lib/core/app_info.dart`, set `feedbackUrl`. For example:
  - `mailto:you@example.com?subject=SI%20Studio%20feedback`
  - a Google Form link
  - `https://github.com/<user>/si-studio/issues/new`

  This shows *Send feedback* buttons on Home and in About.
- **Version:** bump `appVersion` in `lib/core/app_info.dart` (and `version:` in `pubspec.yaml`) for each release, so testers can report which version they used.
- **Test on two browsers:** open the link on your phone and on a laptop. Run one of the *Try an example* cards on Home.

### Suggested message for testers

> SI Studio is a quick signal-integrity checker for PCB layouts (SPI, QSPI, I²C, RGMII, USB 2.0/3.0, PCIe, HDMI).
> Open: <link> – no install needed; it works best in Chrome or Edge on a laptop.
> Tap a *Try an example* card to see what it does, then try one of your own interfaces.
> Your analyses stay in your browser. Results are a preliminary check, not compliance.
> Feedback: <feedback link>

---

## 4. Good to know

- **Install as an app:** in Chrome or Edge use *⋮ → Install SI Studio*; on a phone use *Add to Home screen*. This gives an icon and a full-screen window.
- **Where data lives:** in the browser's IndexedDB on that device. Clearing site data deletes it, and private windows don't keep it. To move analyses, export JSON on a result, or use *Libraries → export* for libraries.
- **Speed:**
  - Simulations run in the page, so the screen pauses briefly while one runs (usually well under a second).
  - A parameter sweep updates its progress after each configuration.
  - The first visit downloads a few MB; later visits load from the browser cache.
- **Supported browsers:** current Chrome, Edge, Firefox and Safari (desktop and mobile).

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| GitHub Pages shows a blank page | The app was built for another path. The workflow uses the repository name automatically. If you build by hand, use `flutter build web --release --base-href "/<repo>/"` |
| GitHub Pages shows 404 | Set *Settings → Pages → Source* to **GitHub Actions** and re-run the workflow (*Actions → Deploy web app → Run workflow*) |
| The workflow fails at `flutter test` | A test is failing. Open the log, fix it locally with `flutter test`, then push again |
| "Storage is unavailable" in About | The tester is in a private window or blocks site data; the session works but isn't saved |
| Downloads don't appear | Allow downloads for the site; the browser may ask the first time several files are exported together |
