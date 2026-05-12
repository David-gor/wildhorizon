# WildHorizon

Flutter app (map + OSM bike trails, rides, rider profile).

## For you (first push to GitHub)

1. Create a **new empty** repository on GitHub (no README, no .gitignore).
2. In this folder run (replace `YOUR_USER` and `YOUR_REPO`):

```bash
cd ~/Documents/mtb_app
git remote add origin https://github.com/YOUR_USER/YOUR_REPO.git
git branch -M main
git push -u origin main
```

If GitHub asks for a password, use a **Personal Access Token** (Settings → Developer settings → Tokens), not your account password.

## For your friend (after you pushed)

```bash
git clone https://github.com/YOUR_USER/YOUR_REPO.git
cd YOUR_REPO
flutter pub get
flutter run -d macos
```

Then open the folder in Cursor or VS Code.

## Invite your friend on GitHub

Repository → **Settings** → **Collaborators** → **Add people**.

## macOS / iCloud note

If `flutter run` hits **CodeSign** errors under iCloud (`Documents`), build from a copy outside iCloud (e.g. `~/flutter/local_projects/mtb_app`) or clone the repo there—same Git remote, same `git pull` / `git push`.

## Workflow

- Before coding: `git pull`
- After a sensible chunk: `git add -A` → `git commit -m "..."` → `git push`
- Optional: use branches (`git checkout -b feature/foo`) and **Pull requests** on GitHub.
