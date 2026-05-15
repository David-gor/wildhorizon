# Sync checklist (two people, one GitHub repo)

Git syncs **commits on GitHub**, not your two laptop folders directly. Same commands for everyone—only the `cd` path differs.

**David’s machine:** the real repo with `.git` is **`~/Developer/mtb_app`**. A partial copy under `~/Documents/mtb_app` is not the Git project—open **`Developer/mtb_app`** in Cursor and run Flutter from there.

---

## One-time (each person)

- [ ] Clone the repo (or already have it): `git clone <repo-url>` then `cd <project-folder>`
- [ ] Check remote: `git remote -v` → `origin` should be the **shared** repo URL
- [ ] Friend: accept **Collaborator** invite on GitHub (repo → Settings → Collaborators) if they need push access

---

## Every session (before you code)

- [ ] `cd` into the project folder (the one that contains `pubspec.yaml`)
- [ ] `git pull origin main`
- [ ] Fix any merge messages if Git asks, then continue

---

## When you have something worth sharing

- [ ] `git status` (see what changed)
- [ ] `git add -A`
- [ ] `git commit -m "Short plain description of what changed"`
- [ ] `git push origin main`

If `git push` fails because the remote has new commits:

- [ ] `git pull origin main --rebase`
- [ ] Fix conflicts if any, then `git add -A` and `git rebase --continue` (only if Git stopped for conflicts)
- [ ] `git push origin main`

---

## When your partner says they pushed

- [ ] `git pull origin main`
- [ ] Run the app (`flutter run` / IDE) and sanity-check

---

## Optional: before a big change

- [ ] `git pull origin main` again
- [ ] Consider a branch: `git checkout -b feature/short-name` then push with `git push -u origin feature/short-name` and open a **Pull Request** on GitHub (good for large or risky edits)

---

## Do not

- Rely on AirDrop / USB / “copy the whole folder” as your sync story—use Git push/pull to the same `origin`.
- Commit secrets (API keys, keystores). Use env files that are **gitignored** or GitHub secrets for CI.

---

## Quick verify

```bash
git remote -v
git branch
git status
git log -1 --oneline
```

Same `origin` URL + same default branch + recent `pull`/`push` = you stay in sync.
